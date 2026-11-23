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
      Syrus::PluginRegistry.providers_for(:permission_provider).each_with_object({}) do |provider, schemas|
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
      Syrus::PluginRegistry.providers_for(:permission_provider).each_with_object({}) do |provider, presets|
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
    #
    # +cache:+ lets a caller classifying every descriptor reuse one registry
    # and plugin-descriptor snapshot instead of rebuilding them per lookup.
    def self.essential_for?(operation, role:, cache: nil)
      cache ||= {}
      role = role.to_s
      surface = if COWORKER_ROLES.include?(role) then :coworker
      elsif role == AgentRole::AGENT_INSIGHT then :agent_insight
      elsif AgentRole::WORKFLOW_ROLES.include?(role) then :workflow
      else :chat
      end
      entries_for = ->(name) { cache[[ :entries, name ]] ||= McpToolRegistry.entries(surface: name).select(&:descriptor) }
      core = entries_for.call(surface).select { |entry| entry.descriptor.operation == operation.to_s }
      # Coworkers share the chat essentials even where their entry carries its
      # own operation identifier.
      core = entries_for.call(:chat).select { |entry| entry.descriptor.operation == operation.to_s } if core.empty? && surface == :coworker
      return core.any? { |entry| entry.descriptor.essential? } if core.any?

      (cache[:plugin] ||= plugin_tool_descriptors + permission_provider_descriptors).any? do |descriptor|
        descriptor.operation == operation.to_s && descriptor.essential?
      end
    end

    # Essential for every role that could ever hold a rule on it.
    def self.essential_everywhere?(descriptor, cache: nil)
      descriptor.requestable_roles.all? { |role| essential_for?(descriptor.operation, role:, cache:) }
    end

    def self.as_json(descriptor)
      descriptor.to_h.except(:classifier, :fingerprint_normalizer, :redactor).merge(
        resource_scope: descriptor.resource_scope.to_h
      )
    end

    def self.permission_provider_descriptors
      Syrus::PluginRegistry.providers_for(:permission_provider)
        .flat_map do |provider|
          invoke(provider, :permission_capability_descriptors, []) { provider.permission_capability_descriptors }
        end
    end
    private_class_method :permission_provider_descriptors

    def self.plugin_tool_descriptors
      %i[mcp_tool_set chat_mcp_tool_set].flat_map do |extension_point|
        Syrus::PluginRegistry.providers_for(extension_point).flat_map do |provider|
          invoke(provider, :tool_definitions, [], extension_point:) { Syrus::PluginRegistry.all_tool_definitions(provider) }.filter_map do |definition|
            definition = definition.symbolize_keys
            next unless definition[:capability_descriptor]

            CapabilityDescriptorAdapter.for_plugin_definition(definition)
          end
        end
      end
    end
    private_class_method :plugin_tool_descriptors

    def self.invoke(provider, operation, decline, extension_point: :permission_provider, &block)
      Syrus::PluginInvocation.value(Syrus::PluginInvocation.call(
        extension_point:, provider:, operation:, on_decline: decline, &block
      ))
    end
    private_class_method :invoke
  end
end
