module Permissions
  class CoworkerCapabilityDiscovery
    # +blocker+ names what stands between the coworker and execution
    # (permission, policy, plugin, resource, infrastructure); +next_action+ is
    # either a request_permission payload (permission is the only blocker) or
    # an owner-facing remediation (anything else). Only the former can be
    # fixed by granting authority.
    Result = Data.define(:capability, :operations, :required_scope, :effective_policy, :state, :lock_reason,
      :blocker, :prerequisites, :permitted_scope, :next_action, :tools) do
      def initialize(blocker: nil, prerequisites: [], permitted_scope: nil, next_action: nil, tools: [], **attributes)
        super(blocker:, prerequisites:, permitted_scope:, next_action:, tools:, **attributes)
      end

      def to_h
        { capability:, operations:, required_scope:, effective_policy:, state:, lock_reason:, blocker:,
          prerequisites:, permitted_scope:, next_action:, tools: }.compact
      end
    end

    INFRASTRUCTURE_REMEDIATION = {
      "confinement_worker_unavailable" => "No live worker is available to run privileged coworker tools. Bring a confinement-capable worker online.",
      "confinement_configuration_missing" => "The confined-coworker runtime is not configured on the workers. Complete the confinement configuration on a worker.",
      "confinement_probe_failed" => "The confined-coworker verification probe failed on the workers. Fix the confinement runtime so the probe passes.",
      "confinement_probe_missing" => "No worker has reported a confined-coworker verification probe yet. Check that a confinement-capable worker is running and has completed its probe.",
      "broker_authorization_unavailable" => "The credential broker (credential_store plugin) is disabled or unhealthy. Enable or repair it.",
      "provider_plugin_disabled" => "The plugin that provides this capability is disabled. Enable it in the plugin settings.",
      "provider_unavailable" => "The provider for this capability is unhealthy or switched off. Restore it before retrying."
    }.freeze

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

    # The capability that owns +tool_name+, in whatever state it is in. Used to
    # attach a next action to a not_authorized refusal.
    def for_tool(tool_name)
      grouped_descriptors.each do |capability, descriptors|
        return result_for(capability, descriptors) if descriptors.first.any? { |tool| tool.tool_name == tool_name.to_s }
      end
      nil
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
      # A tool may ride on a grant while belonging to a stricter family (an
      # execute tool under a read grant). That family's coworker policy must
      # not hide the grant's own operations, so judge by the grant family.
      primary = descriptors.select { |descriptor| descriptor.capability.sub(/@v\d+\z/, "") == capability }
      primary = descriptors if primary.empty?
      eligible = primary.any? { |descriptor| descriptor.requestable_roles.include?(context.role) }
      policy = effective_policy(primary)
      availability = tools.map { |tool| tool_availability(tool) }
        .max_by { |state| availability_rank.fetch(state.to_sym) }
      grant = tools.filter_map(&:grant).first&.with_indifferent_access
      scope_options = grant ? scope_options_for(grant) : []
      availability, grant_block = refine_availability(availability, grant:, scope_options:)
      state, reason = state_and_reason(availability:, eligible:, policy:)
      granted = grant.nil? || context.granted_capabilities.include?(capability)
      if state.in?(%w[available requestable]) && !granted
        state = "requestable"
        reason = "capability_not_granted"
      end
      reason = grant_block if grant_block && state.in?(%w[unavailable resource_unconfigured])

      Result.new(
        capability: capability,
        operations: descriptors.map(&:operation).uniq.sort,
        required_scope: required_scope(descriptors),
        effective_policy: policy.to_s,
        state: state,
        lock_reason: reason,
        blocker: blocker_for(state),
        prerequisites: prerequisites(availability:, grant:, granted:, eligible:, reason: grant_block || reason, scope_options:, state:),
        permitted_scope: permitted_scope(capability, scope_options),
        next_action: next_action(capability, tools, descriptors, state:, reason:, grant:, scope_options:),
        tools: tools.map(&:tool_name).uniq.sort
      )
    end

    # Confinement/broker (privileged grants) and the absence of any eligible
    # scope option make a known capability unusable without hiding it.
    def refine_availability(availability, grant:, scope_options:)
      return [ availability, nil ] unless availability.to_sym == :available && grant

      if grant[:privileged] && (blocked = confinement_block(grant))
        return [ :unavailable, blocked ]
      end
      return [ :resource_unconfigured, "no_eligible_resource" ] if grant[:scope_options_callback] && scope_options.empty?

      [ availability, nil ]
    end

    def confinement_block(grant)
      session = context.chat_session
      return unless session.respond_to?(:coworker_grant_availability)

      result = session.coworker_grant_availability(grant.fetch(:name))
      return if result.nil? || result[:available]

      result[:reason].presence || "confinement_worker_unavailable"
    end

    def scope_options_for(grant)
      callback = grant[:scope_options_callback]
      return [] unless callback

      Array(callback.call(user: context.user)).map do |value|
        label = grant[:scope_label_callback]&.call(value)
        { value: value, label: label }.compact
      end
    rescue StandardError => error
      Rails.logger.warn("[CoworkerCapabilityDiscovery] scope options unavailable: #{error.class}: #{error.message}")
      []
    end

    def permitted_scope(capability, scope_options)
      granted = context.capability_scopes[capability]
      return if granted.blank? && scope_options.empty?

      { granted: granted.presence, options: scope_options.presence }.compact
    end

    def blocker_for(state)
      {
        "available" => nil, "requestable" => "permission", "prohibited" => "policy",
        "plugin_disabled" => "plugin", "resource_unconfigured" => "resource", "unavailable" => "infrastructure"
      }.fetch(state)
    end

    def prerequisites(availability:, grant:, granted:, eligible:, reason:, scope_options:, state:)
      infrastructure_block = reason.to_s.start_with?("confinement", "broker")
      provider_ok = availability.to_sym != :plugin_disabled && (availability.to_sym != :unavailable || infrastructure_block)
      list = [ { id: "provider", satisfied: provider_ok, reason: provider_ok ? nil : availability_reason(availability) } ]
      if grant&.dig(:privileged)
        list << { id: "confinement", satisfied: !infrastructure_block, reason: infrastructure_block ? reason : nil }
      end
      if grant&.dig(:scope_options_callback)
        list << { id: "resource", satisfied: scope_options.any?, reason: scope_options.any? ? nil : "no_eligible_resource" }
      end
      list << { id: "role_eligible", satisfied: eligible, reason: eligible ? nil : "role_not_eligible" }
      list << { id: "permission", satisfied: granted && state == "available", reason: granted ? nil : "capability_not_granted" }
      list.map(&:compact)
    end

    def next_action(capability, tools, descriptors, state:, reason:, grant:, scope_options:)
      resume = { discover_with: { tool: "discover_coworker_capabilities", query: capability, include_non_requestable: true },
                 tools: tools.map(&:tool_name).uniq.sort }
      case state
      when "requestable" then request_action(capability, descriptors, grant:, scope_options:, resume:)
      when "available", "prohibited" then (state == "prohibited" ? owner_action("owner_policy", reason, capability, resume) : nil)
      else owner_action(state, reason, capability, resume, grant:)
      end
    end

    def request_action(capability, descriptors, grant:, scope_options:, resume:)
      eligible = descriptors.select { |descriptor| requestable_descriptor?(descriptor, capability, grant) }
      return owner_action("owner_policy", "descriptor_not_requestable", capability, resume) if eligible.empty?

      scope_key = nil
      requests = eligible.map do |descriptor|
        scope = {}
        key = scope_key_for(descriptor)
        scope[key] = scope_options.first[:value] if key && scope_options.any?
        {
          capability: descriptor.capability, operation: descriptor.operation, resource_scope: scope,
          purpose: "Needed to use #{capability}; state the concrete task before sending."
        }
      end
      {
        type: "request_permission", tool: "request_permission", requests: requests,
        scope_choices: scope_options.presence, grants_authority: false, resume: resume
      }.compact
    end

    def requestable_descriptor?(descriptor, capability, grant)
      return false unless descriptor.requestable_roles.include?(context.role)
      return false if grant && descriptor.capability.sub(/@v\d+\z/, "") != capability

      Permissions::Catalog.find!(capability: descriptor.capability, operation: descriptor.operation)
        .requestable_roles.include?(context.role)
    rescue Permissions::Catalog::UnknownCapability
      false
    end

    def scope_key_for(descriptor)
      options = descriptor.resource_scope.to_h[:options].to_h
      (Array(options[:hierarchy]).first || Array(options[:required]).first)&.to_s
    end

    def owner_action(state, reason, capability, resume, grant: nil)
      remediation = INFRASTRUCTURE_REMEDIATION[reason.to_s]
      remediation ||= grant&.dig(:unconfigured_remediation) if reason.to_s.in?(%w[no_eligible_resource required_resource_unconfigured])
      remediation ||= "Ask the owner to configure the resources #{capability} needs, then rediscover." if state == "resource_unconfigured"
      remediation ||= "Ask the owner to change their permission policy for #{capability}." if state == "owner_policy"
      remediation ||= "Ask the owner to resolve the blocker, then rediscover."
      {
        type: "owner_remediation", reason: reason, message: remediation,
        grants_authority: false, grant_alone_sufficient: false,
        warning: "Requesting or granting permission will not make this safe to run.", resume: resume
      }
    end

    def effective_policy(descriptors)
      policies = descriptors.map do |descriptor|
        permission_management.explain(
          descriptor: descriptor,
          role: context.role,
          resource_scope: {},
          arguments: {},
          context: {
            role: context.role, agent_id: context.agent_actor&.id,
            subject_selector_type: "agent", subject_selector_id: context.agent_actor&.id&.to_s,
            subject_repository_id: context.repository&.id,
            chat_session_id: context.chat_session&.id, job_id: context.job&.id
          }.compact
        ).policy
      rescue ArgumentError
        descriptor.defaults.fetch(context.role, :deny)
      end
      policies.min_by { |policy| Permissions::PolicyEvaluator::POLICY_RANK.fetch(policy) } || :deny
    end

    def state_and_reason(availability:, eligible:, policy:)
      return [ availability.to_s, availability_reason(availability) ] unless availability.to_sym == :available
      return [ "prohibited", "role_not_eligible" ] unless eligible
      return [ "prohibited", "effective_policy_denies" ] if policy == :deny
      return [ "available", nil ] if policy == :allow

      [ "requestable", "operation_requires_approval" ]
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
