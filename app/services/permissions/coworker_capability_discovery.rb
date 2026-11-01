module Permissions
  class CoworkerCapabilityDiscovery
    Result = Data.define(:capability, :operations, :required_scope, :effective_policy, :state, :lock_reason) do
      def to_h
        { capability:, operations:, required_scope:, effective_policy:, state:, lock_reason: }.compact
      end
    end

    def initialize(context)
      @context = context
    end

    def call(query: nil, include_non_requestable: false)
      grouped_descriptors.filter_map do |capability, descriptors|
        result = result_for(capability, descriptors)
        next if !include_non_requestable && result.state != "requestable"
        next if query.present? && !search_text(result).include?(query.to_s.downcase)

        result
      end.sort_by(&:capability)
    end

    private

    attr_reader :context

    def grouped_descriptors
      Mcp::CoworkerToolCatalog.all
        .reject(&:ungated)
        .group_by(&:capability)
        .transform_values { |tools| tools.map { |tool| descriptor_for(tool) }.compact.uniq }
    end

    def descriptor_for(tool)
      if tool.tool
        McpToolRegistry.entry_for(tool.tool)&.descriptor
      else
        definition = plugin_definition(tool)
        Permissions::CapabilityDescriptorAdapter.for_plugin_definition(definition) if definition
      end
    end

    def plugin_definition(tool)
      keywords = { tier: tool.tier }
      if tool.provider.method(:tool_definitions).parameters.any? { |type, name| [ :key, :keyreq ].include?(type) && name == :chat_session }
        keywords[:chat_session] = context.chat_session
      end
      definitions = tool.provider.tool_definitions(**keywords)
      definition = definitions.find { |candidate| (candidate[:name] || candidate["name"]).to_s == tool.tool_name }
      definition&.merge(requestable_roles: [ AgentRole::COWORKER_CHAT, AgentRole::COWORKER ])
    rescue ArgumentError
      nil
    end

    def result_for(capability, descriptors)
      eligible = descriptors.any? { |descriptor| descriptor.requestable_roles.include?(context.role) }
      granted = context.granted_capabilities.include?(capability.to_s)
      policy = effective_policy(descriptors)
      state, reason = state_and_reason(eligible:, granted:, policy:)

      Result.new(
        capability: capability,
        operations: descriptors.map(&:operation).uniq.sort,
        required_scope: required_scope(descriptors),
        effective_policy: policy.to_s,
        state: state,
        lock_reason: reason
      )
    end

    def effective_policy(descriptors)
      policies = descriptors.map do |descriptor|
        Permissions::Management.new(context.user).explain(
          descriptor: descriptor,
          role: context.role,
          resource_scope: {},
          arguments: {},
          context: { role: context.role, agent_id: context.agent_actor&.id }
        ).policy
      rescue ArgumentError
        descriptor.defaults.fetch(context.role, :deny)
      end
      policies.min_by { |policy| Permissions::PolicyEvaluator::POLICY_RANK.fetch(policy) } || :deny
    end

    def state_and_reason(eligible:, granted:, policy:)
      return [ "prohibited", "role_not_eligible" ] unless eligible
      return [ "prohibited", "effective_policy_denies" ] if policy == :deny
      return [ "available", nil ] if granted

      [ "requestable", "capability_not_granted" ]
    end

    def required_scope(descriptors)
      scopes = descriptors.map { |descriptor| descriptor.resource_scope.to_h }.uniq
      scopes.one? ? scopes.first : scopes
    end

    def search_text(result)
      [ result.capability, *result.operations, result.state, result.lock_reason ].compact.join(" ").downcase
    end
  end
end
