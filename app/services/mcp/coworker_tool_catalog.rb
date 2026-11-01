module Mcp
  class CoworkerToolCatalog
    Descriptor = Data.define(:tool_name, :capability, :ungated, :tier, :tool, :provider, :availability_state, :description, :definition) do
      def initialize(availability_state: :available, description: nil, definition: nil, **attributes)
        super(availability_state:, description:, definition:, **attributes)
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
            tier: entry.tier, tool: entry.tool, provider: nil, description: entry.tool.description_value)
        end
      end

      def plugin_descriptors(chat_session: nil)
        plugin_providers.flat_map do |provider, plugin_state|
          definitions = definitions_for(provider, chat_session: chat_session)
          by_name = definitions.index_by { |definition| value(definition, :name).to_s }
          grants = grant_tools(provider)
          granted_names = grants.values.flatten.to_set
          unclassified = definitions.select do |definition|
            value(definition, :coworker_safe) == true && value(definition, :ungated) != true &&
              !granted_names.include?(value(definition, :name).to_s)
          end
          if unclassified.any?
            name = value(unclassified.first, :name).to_s
            raise ArgumentError, "coworker tool #{name.inspect} has no resolvable grant and is not ungated"
          end

          granted = grants.flat_map do |capability, names|
            names.map do |name|
              definition = by_name[name]
              Descriptor.new(tool_name: name, capability: capability, ungated: false,
                tier: definition ? definition_tier(provider, name, chat_session: chat_session) : :essential,
                tool: nil, provider: provider,
                availability_state: definition ? provider_state(provider, plugin_state, chat_session:) : :unavailable,
                description: definition && value(definition, :description), definition: definition)
            end
          end
          ungated = definitions.filter_map do |definition|
            next unless value(definition, :coworker_safe) == true && value(definition, :ungated) == true

            name = value(definition, :name).to_s
            Descriptor.new(tool_name: name, capability: value(definition, :capability)&.to_s, ungated: true,
              tier: definition_tier(provider, name, chat_session: chat_session), tool: nil, provider: provider,
              availability_state: provider_state(provider, plugin_state, chat_session:),
              description: value(definition, :description), definition: definition)
          end
          granted + ungated
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
          providers = manifest.provides[:chat_mcp_tool_set] || manifest.provides["chat_mcp_tool_set"]
          Array(providers).map { |provider| [ provider, state ] }
        end
      end

      def provider_state(provider, plugin_state, chat_session:)
        return plugin_state unless plugin_state == :available
        return provider.coworker_discovery_state(chat_session) if provider.respond_to?(:coworker_discovery_state)

        :available
      rescue ActiveRecord::ActiveRecordError
        :unavailable
      end

      def definitions_for(provider, chat_session: nil)
        parameters = provider.method(:tool_definitions).parameters
        accepts_chat = parameters.any? { |type, name| [ :key, :keyreq ].include?(type) && name == :chat_session }
        return provider.tool_definitions(tier: nil) unless chat_session && accepts_chat

        %i[essential deferred].flat_map { |tier| provider.tool_definitions(tier: tier, chat_session: chat_session) }
      rescue StandardError => error
        Rails.logger.warn("[CoworkerToolCatalog] #{provider} definitions unavailable: #{error.class}: #{error.message}")
        []
      end

      def definition_tier(provider, name, chat_session: nil)
        parameters = provider.method(:tool_definitions).parameters
        accepts_chat = parameters.any? { |type, parameter_name| [ :key, :keyreq ].include?(type) && parameter_name == :chat_session }
        %i[essential deferred].find do |tier|
          keywords = { tier: tier }
          keywords[:chat_session] = chat_session if accepts_chat
          Array(provider.tool_definitions(**keywords)).any? { |definition| value(definition, :name).to_s == name }
        end || :essential
      end

      def grant_tools(provider)
        Array(provider.respond_to?(:coworker_grants) ? provider.coworker_grants : []).each_with_object({}) do |grant, tools|
          attributes = grant.to_h.stringify_keys
          tools[attributes.fetch("name").to_s] = Array(attributes["tools"]).map(&:to_s)
        end
      end

      def value(definition, key) = definition[key] || definition[key.to_s]
    end
  end
end
