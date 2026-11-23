module Permissions
  class Catalog
    class UnknownCapability < ArgumentError; end

    def self.descriptors
      existing = (McpToolRegistry.entries.map(&:descriptor) + plugin_tool_descriptors + ExecutionActions.descriptors)
        .uniq { |descriptor| [ descriptor.capability, descriptor.operation ] }
      (existing + permission_provider_descriptors)
        .group_by { |descriptor| [ descriptor.capability, descriptor.operation ] }
        .map do |(capability, operation), registrations|
          contracts = registrations.map(&:contract_key).uniq
          if contracts.many?
            raise ArgumentError,
              "permission operation #{operation.inspect} for capability #{capability.inspect} has conflicting contracts"
          end
          # Where one surface classifies the operation as essential and another
          # does not (a coworker sees it under delegation), the deniable variant
          # is the one rules and previews are about.
          registrations.min_by { |descriptor| descriptor.essential? ? 1 : 0 }
        end
    end

    def self.resource_scopes
      Syrus::Plugin::Toolkit.permission_providers.each_with_object({}) do |provider, schemas|
        invoke(provider, :permission_resource_scopes, {}) { provider.permission_resource_scopes }.each do |type, schema|
          existing = schemas[type]
          if existing && !existing.equal?(schema)
            raise ArgumentError, "permission resource scope #{type.inspect} is registered by more than one provider"
          end
          schemas[type] = schema
        end
      end.freeze
    end

    def self.presets
      Syrus::Plugin::Toolkit.permission_providers.each_with_object({}) do |provider, presets|
        invoke(provider, :permission_presets, {}) { provider.permission_presets }.each do |name, preset|
          raise ArgumentError, "permission preset #{name.inspect} is registered by more than one provider" if presets.key?(name)

          presets[name] = preset
        end
      end.freeze
    end

    # `from:` lets a caller that resolves many capabilities (a rule list
    # serialization) reuse one descriptors snapshot instead of rebuilding the
    # whole catalog for every lookup.
    def self.find!(capability:, operation: nil, from: nil)
      matches = (from || descriptors).select { |descriptor| descriptor.capability == capability.to_s }
      matches.select! { |descriptor| descriptor.operation == operation.to_s } if operation.present?
      raise UnknownCapability, "unknown permission capability or operation" unless matches.one?

      matches.first
    end

    COWORKER_ROLES = [ AgentRole::COWORKER_CHAT, AgentRole::COWORKER ].freeze

    # Whether +operation+ is an agent essential for agents running as +role+.
    # Core tools are classified per surface; a plugin operation's own flag
    # applies to every role.
    def self.essential_for?(operation, role:)
      role = role.to_s
      surface = if COWORKER_ROLES.include?(role) then :coworker
      elsif role == AgentRole::AGENT_INSIGHT then :agent_insight
      elsif AgentRole::WORKFLOW_ROLES.include?(role) then :workflow
      else :chat
      end
      core = McpToolRegistry.entries(surface:).select { |entry| entry.descriptor&.operation == operation.to_s }
      # Coworkers share the chat essentials even where their entry carries its
      # own operation identifier.
      core = McpToolRegistry.entries(surface: :chat).select { |entry| entry.descriptor&.operation == operation.to_s } if core.empty? && surface == :coworker
      return core.any? { |entry| entry.descriptor.essential? } if core.any?

      (plugin_tool_descriptors + permission_provider_descriptors).any? do |descriptor|
        descriptor.operation == operation.to_s && descriptor.essential?
      end
    end

    # Essential for every role that could ever hold a rule on it.
    def self.essential_everywhere?(descriptor)
      descriptor.requestable_roles.all? { |role| essential_for?(descriptor.operation, role:) }
    end

    def self.as_json(descriptor)
      descriptor.to_h.except(:classifier, :fingerprint_normalizer, :redactor).merge(
        resource_scope: descriptor.resource_scope.to_h
      )
    end

    def self.permission_provider_descriptors
      Syrus::Plugin::Toolkit.permission_providers
        .flat_map do |provider|
          invoke(provider, :permission_capability_descriptors, []) { provider.permission_capability_descriptors }
        end
    end
    private_class_method :permission_provider_descriptors

    def self.plugin_tool_descriptors
      tool_descriptors(Syrus::Plugin::Toolkit.workflow_tool_sets) +
        tool_descriptors(Syrus::Plugin::Toolkit.chat_tool_sets)
    end
    private_class_method :plugin_tool_descriptors

    def self.tool_descriptors(providers)
      providers.flat_map do |provider|
        invoke(provider, :tool_definitions, []) { Syrus::PluginRegistry.all_tool_definitions(provider) }.filter_map do |definition|
          definition = definition.symbolize_keys
          next unless definition[:capability_descriptor]

          CapabilityDescriptorAdapter.for_plugin_definition(definition)
        end
      end
    end
    private_class_method :tool_descriptors

    def self.invoke(provider, operation, decline, &block)
      Syrus::PluginInvocation.value(Syrus::PluginInvocation.call(
        extension_point: :toolkit, provider:, operation:, on_decline: decline, &block
      ))
    end
    private_class_method :invoke
  end
end
