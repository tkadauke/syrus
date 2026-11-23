module Permissions
  class CapabilityRegistryValidator
    Registration = Data.define(:tool_name, :surface, :source, :descriptor, :explicit_descriptor,
      :ungated)
    Finding = Data.define(:code, :message, :registrations) do
      def to_h = { code: code, message: message, registrations: registrations }
    end

    class ValidationError < StandardError
      attr_reader :findings

      def initialize(findings)
        @findings = findings
        super("Capability registry validation failed:\n- #{findings.map(&:message).join("\n- ")}")
      end
    end

    attr_reader :registrations

    def self.for_application
      core = McpToolRegistry.entries.map do |entry|
        Registration.new(
          tool_name: entry.tool_name, surface: entry.surface, source: "core",
          descriptor: entry.descriptor, explicit_descriptor: entry.explicit_descriptor, ungated: entry.ungated
        )
      end
      plugin = Syrus::Plugin::Toolkit.workflow_tool_sets.flat_map do |provider|
        plugin_registrations(provider, :mcp_tool_set)
      end
      plugin.concat(Syrus::Plugin::Toolkit.chat_tool_sets.flat_map do |provider|
        plugin_registrations(provider, :chat_mcp_tool_set)
      end)
      permission_providers = Syrus::Plugin::Toolkit.permission_providers.flat_map do |provider|
        descriptors = Syrus::PluginInvocation.value(Syrus::PluginInvocation.call(
          extension_point: :toolkit, provider:, operation: :permission_capability_descriptors,
          on_decline: []
        ) { provider.permission_capability_descriptors })
        descriptors.map do |descriptor|
          Registration.new(
            tool_name: descriptor.operation, surface: :permission_provider,
            source: provider.name.presence || provider.to_s,
            descriptor: descriptor, explicit_descriptor: true, ungated: false
          )
        end
      end
      new(core + plugin + permission_providers, complete: true)
    end

    def self.plugin_registrations(provider, extension_point)
      definitions = Syrus::PluginInvocation.value(Syrus::PluginInvocation.call(
        extension_point: :toolkit, provider:, operation: :tool_definitions, on_decline: []
      ) { Syrus::PluginRegistry.all_tool_definitions(provider) })
      definitions.map do |definition|
        definition = definition.symbolize_keys
        descriptor = CapabilityDescriptorAdapter.for_plugin_definition(definition)
        Registration.new(
          tool_name: definition[:name].to_s,
          surface: extension_point,
          source: provider.name.presence || provider.to_s,
          descriptor: descriptor,
          explicit_descriptor: definition[:capability_descriptor].present?,
          ungated: definition[:ungated] == true
        )
      end
    end
    private_class_method :plugin_registrations

    # +complete+ marks the whole application's registrations, the only set
    # against which a classification entry can be called stale.
    def initialize(registrations, complete: false)
      @registrations = registrations
      @complete = complete
    end

    def validate!
      current_findings = findings
      raise ValidationError, current_findings if current_findings.any?
      true
    end

    def findings
      missing_descriptor_findings + bundle_findings +
        tool_mapping_findings + descriptor_conflict_findings + identifier_findings +
        consequence_findings + ungated_findings + stale_classification_findings
    end

    def coverage
      descriptors = registrations.filter_map(&:descriptor)
      explicit_descriptors = registrations.count { |registration| registration.descriptor && registration.explicit_descriptor }
      roles = descriptors.flat_map(&:requestable_roles).uniq.sort
      effects = CapabilityDescriptor::EFFECTS.index_with { 0 }
      descriptors.each { |descriptor| descriptor.effects.each { |effect| effects[effect] += 1 } }

      {
        tools: registrations.length,
        described_tools: descriptors.length,
        explicit_descriptors: explicit_descriptors,
        ungated_tools: registrations.count(&:ungated),
        essential_operations: registrations.count { |registration| registration.descriptor&.essential? },
        roles: roles.index_with do |role|
          role_descriptors = descriptors.select { |descriptor| descriptor.requestable_roles.include?(role) }
          { descriptors: role_descriptors.length, defaults: role_descriptors.map { |descriptor| descriptor.defaults.fetch(role) }.tally }
        end,
        effects: effects,
        tool_set_bundles: descriptors.map(&:tool_set_bundle).tally
      }
    end

    private

    # Every operation must be classified on purpose: essential, gated by a
    # barrier effect it declares, or deniable for a named reason. A descriptor
    # that is merely "ask by default" with no stated consequence is how an
    # essential operation silently becomes requestable.
    def consequence_findings
      registrations.filter_map do |registration|
        descriptor = registration.descriptor
        next unless descriptor
        next if descriptor.essential? || descriptor.barrier_effects.any? || descriptor.deniable_reason

        finding(:unclassified_consequence, registration,
          "declares no barrier effect, is not essential and names no deniable_reason")
      end
    end

    # `ungated` (registry entries and plugin definitions) must mean exactly
    # what `essential` means on the descriptor every gate evaluates.
    def ungated_findings
      registrations.filter_map do |registration|
        next unless registration.ungated
        next if registration.descriptor&.essential?

        finding(:ungated_not_essential, registration, "is registered ungated but its descriptor is not essential")
      end
    end

    # The core classification table must only name tools that exist on the
    # surface it classifies, so a renamed tool cannot keep a stale entry while
    # its replacement goes unclassified.
    def stale_classification_findings
      return [] unless @complete

      core = registrations.select { |registration| registration.source == "core" }
      registered = core.group_by(&:surface).transform_values { |group| group.map(&:tool_name).to_set }
      return [] if registered.empty?

      stale = ConsequenceClassification::ESSENTIAL.flat_map do |surface, tools|
        tools.reject { |tool| registered.fetch(surface, Set.new).include?(tool) }.map { |tool| [ surface, tool ] }
      end
      core_tools = core.map(&:tool_name).to_set
      stale += ConsequenceClassification::DENIABLE_BY_TOOL.keys.reject { |tool| core_tools.include?(tool) }.map { |tool| [ :any, tool ] }
      stale.map do |surface, tool|
        Finding.new(code: :stale_classification,
          message: "Consequence classification lists #{tool.inspect} on #{surface}, but no core tool by that name is registered there",
          registrations: [])
      end
    end

    def bundle_findings
      registrations.filter_map do |registration|
        next unless registration.descriptor
        next if ToolSetBundles::DEFINITIONS.key?(registration.descriptor.tool_set_bundle)

        finding(:unknown_tool_set_bundle, registration,
          "references unknown tool-set bundle #{registration.descriptor.tool_set_bundle.inspect}")
      end
    end

    def missing_descriptor_findings
      registrations.filter_map do |registration|
        next if registration.ungated
        next if registration.descriptor && registration.explicit_descriptor
        finding(:missing_descriptor, registration,
          I18n.t("server.permissions.capability_registry.missing_descriptor_detail"))
      end
    end

    def tool_mapping_findings
      registrations.group_by { |registration| [ registration.surface, registration.tool_name ] }.filter_map do |(surface, tool_name), group|
        mappings = group.select(&:explicit_descriptor).filter_map(&:descriptor)
          .map { |descriptor| [ descriptor.capability, descriptor.operation ] }.uniq
        next if mappings.length <= 1
        Finding.new(
          code: :conflicting_tool_mapping,
          message: I18n.t("server.permissions.capability_registry.conflicting_tool_mapping",
            surface:, tool_name: tool_name.inspect, mappings: mappings.inspect),
          registrations: group
        )
      end
    end

    def identifier_findings
      canonical_and_alias_findings(:capability) + canonical_and_alias_findings(:operation)
    end

    def descriptor_conflict_findings
      registrations.select { |registration| registration.explicit_descriptor && registration.descriptor }
        .group_by { |registration| registration.descriptor.operation }.filter_map do |operation, group|
        contracts = group.group_by { |registration| registration.descriptor.contract_key }
        next if contracts.one? || coworker_role_projection?(group)
        Finding.new(
          code: :conflicting_descriptor,
          message: I18n.t("server.permissions.capability_registry.conflicting_descriptor",
            operation: operation.inspect, sources: group.map(&:source).uniq.sort.join(", ")),
          registrations: group
        )
      end
    end

    def coworker_role_projection?(registrations)
      return false unless registrations.map(&:source).uniq.one?
      return false unless registrations.map(&:tool_name).uniq.one?
      return false unless registrations.map { |registration| registration.descriptor.authorization_contract_key }.uniq.one?

      coworker_registrations, ordinary_registrations = registrations.partition { |registration| registration.surface == :coworker }
      return false unless coworker_registrations.one? && ordinary_registrations.any?
      return false unless ordinary_registrations.map { |registration| registration.descriptor.contract_key }.uniq.one?

      chat = ordinary_registrations.find { |registration| registration.surface == :chat }&.descriptor
      return false unless chat

      coworker = coworker_registrations.first.descriptor
      original_roles = chat.requestable_roles
      added_roles = [ AgentRole::COWORKER_CHAT, AgentRole::COWORKER ].map(&:to_s)

      coworker.requestable_roles.sort == (original_roles + added_roles).uniq.sort &&
        coworker.defaults.slice(*original_roles) == chat.defaults
    end

    def canonical_and_alias_findings(kind)
      canonical_method = kind
      aliases_method = :"#{kind}_aliases"
      claims = Hash.new { |hash, key| hash[key] = [] }
      registrations.each do |registration|
        next unless registration.descriptor
        canonical = registration.descriptor.public_send(canonical_method)
        claims[canonical] << [ canonical, registration ]
        registration.descriptor.public_send(aliases_method).each { |identifier| claims[identifier] << [ canonical, registration ] }
      end
      claims.filter_map do |identifier, entries|
        canonical_targets = entries.map(&:first).uniq
        next if canonical_targets.one?
        involved = entries.map(&:last).uniq
        Finding.new(
          code: :conflicting_identifier,
          message: I18n.t("server.permissions.capability_registry.conflicting_identifier",
            kind:, identifier: identifier.inspect, targets: canonical_targets.inspect),
          registrations: involved
        )
      end
    end

    def finding(code, registration, detail)
      Finding.new(
        code: code,
        message: I18n.t("server.permissions.capability_registry.registration_finding",
          source: registration.source, surface: registration.surface,
          tool_name: registration.tool_name.inspect, detail:),
        registrations: [ registration ]
      )
    end
  end
end
