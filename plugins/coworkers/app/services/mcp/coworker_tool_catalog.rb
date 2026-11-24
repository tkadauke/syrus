module Mcp
  class CoworkerToolCatalog
    Descriptor = Data.define(:tool_name, :capability, :ungated, :approval_effect, :tier, :tool, :provider, :availability_state, :description, :definition, :grant) do
      def initialize(availability_state: :available, description: nil, definition: nil, grant: nil, approval_effect: false, **attributes)
        super(availability_state:, description:, definition:, grant:, approval_effect:, **attributes)
      end
    end

    class << self
      def resolve(tool_or_name, chat_session: nil)
        name = tool_or_name.is_a?(String) || tool_or_name.is_a?(Symbol) ? tool_or_name.to_s : McpToolRegistry.tool_name_for(tool_or_name)
        core_descriptors.find { |descriptor| descriptor.tool == tool_or_name || descriptor.tool_name == name } ||
          plugin_descriptors(chat_session: chat_session).find { |descriptor| descriptor.tool_name == name }
      end

      def all(chat_session: nil) = core_descriptors + plugin_descriptors(chat_session:)

      private

      def core_descriptors
        McpToolRegistry.entries(surface: :coworker).map do |entry|
          Descriptor.new(tool_name: entry.tool_name, capability: entry.capability&.to_s, ungated: entry.ungated,
            approval_effect: entry.approval_effect,
            tier: entry.tier, tool: entry.tool, provider: nil, description: entry.tool.description_value)
        end
      end

      def plugin_descriptors(chat_session: nil)
        plugin_providers.flat_map do |provider, plugin_state|
          # Discovery is provider-scoped, not tool-scoped. Connection-backed
          # providers may query their models here; resolve that state once for
          # the coherent catalog build and apply it to every advertised tool.
          availability_state = provider_state(provider, plugin_state, chat_session:)
          definitions, tiers_by_name = definitions_and_tiers_for(provider, chat_session: chat_session)
          by_name = definitions.index_by { |definition| value(definition, :name).to_s }
          grant_definitions = grants_for(provider)
          grants = grant_definitions.transform_values { |grant| grant.fetch("tools") }
          granted_names = grants.values.flatten.to_set
          unclassified = definitions.select do |definition|
            value(definition, :ungated) != true && !granted_names.include?(value(definition, :name).to_s)
          end

          granted = grants.flat_map do |capability, names|
            names.map do |name|
              definition = by_name[name]
              definition = definition&.merge(coworker_default_policy: grant_definitions.fetch(capability)["default_policy"])
              essential = definition.present? &&
                Permissions::CapabilityDescriptorAdapter.for_plugin_definition(definition).essential?
              Descriptor.new(tool_name: name, capability: capability, ungated: essential,
                approval_effect: definition.present? && value(definition, :approval_effect) == true,
                tier: definition ? tiers_by_name.fetch(name, :essential) : :essential,
                tool: nil, provider: provider,
                availability_state: definition ? availability_state : :unavailable,
                description: definition && value(definition, :description), definition: definition,
                grant: grant_definitions.fetch(capability))
            end
          end
          unclassified_descriptors = unclassified.to_h do |definition|
            [ value(definition, :name).to_s,
              Permissions::CapabilityDescriptorAdapter.for_plugin_definition(definition) ]
          end
          unclassified_defaults = unclassified_descriptors.values.group_by(&:capability).transform_values do |descriptors|
            descriptors.all? do |descriptor|
              descriptor.defaults.fetch(AgentRole::CHAT_PLANNER, :ask) == :allow &&
                Permissions::CoworkerDefaultPolicy.descriptor_auto_allowable?(descriptor)
            end ? :allow : :ask
          end
          shared = unclassified.map do |definition|
            name = value(definition, :name).to_s
            descriptor = Permissions::CapabilityDescriptorAdapter.for_coworker_parity(
              unclassified_descriptors.fetch(name),
              default_policy: unclassified_defaults.fetch(unclassified_descriptors.fetch(name).capability)
            )
            capability = descriptor.capability.delete_suffix("@v1")
            grant = {
              "name" => capability, "label" => descriptor.presentation.capability_name,
              "description" => descriptor.presentation.capability_description,
              "tools" => [ name ], "default_policy" => "confirm", "maximum_policy" => "auto"
            }
            # An essential plugin operation is essential for coworkers too.
            Descriptor.new(tool_name: name, capability: capability, ungated: descriptor.essential?,
              approval_effect: value(definition, :approval_effect) == true,
              tier: tiers_by_name.fetch(name, :essential), tool: nil, provider: provider,
              availability_state: availability_state,
              description: value(definition, :description),
              definition: definition.merge(capability_descriptor: descriptor), grant: grant)
          end
          ungated = definitions.filter_map do |definition|
            next unless value(definition, :ungated) == true

            name = value(definition, :name).to_s
            Descriptor.new(tool_name: name, capability: value(definition, :capability)&.to_s, ungated: true,
              approval_effect: false,
              tier: tiers_by_name.fetch(name, :essential), tool: nil, provider: provider,
              availability_state: availability_state,
              description: value(definition, :description), definition: definition)
          end
          granted + shared + ungated
        end
      end

      def plugin_providers
        manifests = Syrus::PluginRegistry.all_plugins
        health = Syrus::PluginRegistry.health(enabled_names: manifests.select(&:enabled?).map(&:name))
        manifests.flat_map do |manifest|
          state = if !manifest.enabled?
            :plugin_disabled
          elsif !health.healthy?(manifest.name)
            :unavailable
          else
            :available
          end
          providers = Syrus::Host::Toolkit.chat_tool_set_for(manifest)
          Array(providers).reject { |provider| Mcp::ChatToolParity.provider_hidden?(provider, :coworker) }
            .map { |provider| [ provider, state ] }
        end
      end

      def provider_state(provider, plugin_state, chat_session:)
        return plugin_state unless plugin_state == :available
        return provider.coworker_discovery_state(chat_session) if provider.respond_to?(:coworker_discovery_state)

        :available
      rescue ActiveRecord::ActiveRecordError
        :unavailable
      end

      def definitions_and_tiers_for(provider, chat_session: nil)
        parameters = provider.method(:tool_definitions).parameters
        accepts_chat = parameters.any? { |type, name| [ :key, :keyreq ].include?(type) && name == :chat_session }
        tiers = %i[essential deferred].to_h do |tier|
          keywords = { tier: tier }
          keywords[:chat_session] = chat_session if accepts_chat && chat_session
          [ tier, Array(provider.tool_definitions(**keywords)) ]
        end
        definitions = if chat_session && accepts_chat
          tiers.values.flatten
        else
          Array(provider.tool_definitions(tier: nil))
        end
        definitions = definitions.select do |definition|
          Mcp::ChatToolParity.plugin_definition_in_context?(definition, :coworker, user: chat_session&.user, provider: provider)
        end
        tiers_by_name = tiers.each_with_object({}) do |(tier, tier_definitions), result|
          tier_definitions.each { |definition| result[value(definition, :name).to_s] ||= tier }
        end

        [ definitions, tiers_by_name ]
      rescue StandardError => error
        Rails.logger.warn("[CoworkerToolCatalog] #{provider} definitions unavailable: #{error.class}: #{error.message}")
        [ [], {} ]
      end

      def grants_for(provider)
        Array(provider.respond_to?(:coworker_grants) ? provider.coworker_grants : []).each_with_object({}) do |grant, grants|
          attributes = grant.to_h.stringify_keys
          attributes["tools"] = Array(attributes["tools"]).map(&:to_s)
          grants[attributes.fetch("name").to_s] = attributes
        end
      end

      def value(definition, key) = definition[key] || definition[key.to_s]
    end
  end
end
