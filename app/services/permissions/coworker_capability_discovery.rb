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
      coworker_tools
        .reject(&:ungated)
        .group_by(&:capability)
        .transform_values { |tools| [ tools, tools.map { |tool| descriptor_for(tool) }.compact.uniq ] }
    end

    def descriptor_for(tool)
      if tool.tool
        McpToolRegistry.entry_for(tool.tool)&.descriptor
      elsif tool.definition
        Permissions::CapabilityDescriptorAdapter.for_plugin_definition(
          tool.definition.merge(requestable_roles: [ AgentRole::COWORKER_CHAT, AgentRole::COWORKER ])
        )
      end
    end

    def result_for(capability, tools_and_descriptors)
      tools, descriptors = tools_and_descriptors
      eligible = descriptors.any? { |descriptor| descriptor.requestable_roles.include?(context.role) }
      granted = context.granted_capabilities.include?(capability.to_s)
      policy = effective_policy(descriptors)
      availability = tools.map { |tool| tool_availability(tool) }
        .max_by { |state| availability_rank.fetch(state.to_sym) }
      state, reason = state_and_reason(availability:, eligible:, granted:, policy:)

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
        permission_management.explain(
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

    def state_and_reason(availability:, eligible:, granted:, policy:)
      return [ availability.to_s, availability_reason(availability) ] unless availability.to_sym == :available
      return [ "prohibited", "role_not_eligible" ] unless eligible
      return [ "prohibited", "effective_policy_denies" ] if policy == :deny
      return [ "available", nil ] if granted

      [ "requestable", "capability_not_granted" ]
    end

    def availability_rank
      { unavailable: 0, plugin_disabled: 1, resource_unconfigured: 2, available: 3 }
    end

    def tool_availability(tool)
      return tool.availability_state unless tool.availability_state.to_sym == :available
      return :available if tool.provider

      entry = McpToolRegistry.entry_for(tool.tool)
      return :unavailable unless entry
      return :unavailable if entry.feature_flag && !Feature.public_send("#{entry.feature_flag}_enabled?")

      role_flag = entry.feature_flags_by_role&.fetch(context.role, nil)
      return :unavailable if role_flag && !Feature.public_send("#{role_flag}_enabled?")
      return :resource_unconfigured if repository_scope_required?(entry.descriptor) && context.allowed_repository_ids.empty?

      :available
    end

    def repository_scope_required?(descriptor)
      scope = descriptor.resource_scope.to_h
      scope[:type].to_sym == :repository && Array(scope.dig(:options, :required)).map(&:to_sym).include?(:repository_id)
    end

    def availability_reason(availability)
      {
        plugin_disabled: "provider_plugin_disabled",
        resource_unconfigured: "required_resource_unconfigured",
        unavailable: "provider_unavailable"
      }.fetch(availability.to_sym)
    end

    def permission_management
      @permission_management ||= Permissions::Management.new(context.user)
    end

    def required_scope(descriptors)
      scopes = descriptors.map { |descriptor| descriptor.resource_scope.to_h }.uniq
      scopes.one? ? scopes.first : scopes
    end

    def search_text(result)
      tool_text = grouped_tool_text.fetch(result.capability, [])
      [ result.capability, *result.operations, *tool_text, result.state, result.lock_reason ].compact.join(" ").downcase
    end

    def grouped_tool_text
      @grouped_tool_text ||= coworker_tools
        .reject(&:ungated)
        .group_by(&:capability)
        .transform_values { |tools| tools.flat_map { |tool| [ tool.tool_name, tool.description ] }.compact }
    end

    def coworker_tools
      @coworker_tools ||= Mcp::CoworkerToolCatalog.all(chat_session: context.chat_session)
    end
  end
end
