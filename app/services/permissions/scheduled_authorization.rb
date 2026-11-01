module Permissions
  # Applies the unified permission decision at the MCP dispatch boundary for a
  # scheduled Job. A gated call is represented by one resumable request while
  # later equivalent fires receive a structured skip and may keep working.
  class ScheduledAuthorization
    def self.route(tool:, context:, arguments:) = new(tool:, context:, arguments:).route

    def initialize(tool:, context:, arguments:)
      @tool = tool
      @context = context
      @arguments = arguments
    end

    def route
      return unless context.run? && context.job&.cron?

      descriptor = descriptor_for(tool)
      rules = PermissionRule.active.for_owner(context.user).for_capability(descriptor.capability).map(&:to_policy_rule)
      decision = Permissions::LeaseAuthorizer.call(
        descriptor:, owner: context.user, role: context.role, resource_scope: {}, rules:,
        context: evaluator_context, arguments:
      ).decision
      return if decision.allow?
      return AuthorizationRequestRouter::Result.new(request: nil, status: :policy_denied) if decision.deny?

      fingerprint = InvocationFingerprint.call(descriptor:, arguments:)
      result = AuthorizationRequestRouter.route!(
        user: context.user, repository: context.repository, origin: context.run,
        occurrence_origin: context.job, subject: context.agent_actor || context.user,
        runtime_role: context.role, deduplication_key: deduplication_key(decision, fingerprint),
        purpose: "Run #{McpToolRegistry.tool_name_for(tool)} for scheduled work",
        capability: decision.invocation.capability, operation: decision.invocation.operation,
        occurrence_metadata: { run_id: context.run.id, scheduled_task_id: context.job.scheduled_task_id },
        item_attributes: item_attributes(descriptor, decision, fingerprint)
      )
      checkpoint!(result.request) if result.created?
      result
    end

    private

    attr_reader :tool, :context, :arguments

    def descriptor_for(value)
      value.respond_to?(:capability_descriptor) ? value.capability_descriptor : McpToolRegistry.entry_for(value).descriptor
    end

    def evaluator_context
      { role: context.role, repository_id: context.repository&.id, job_id: context.job.id,
        run_id: context.run.id, subject_selector_type: "workflow_role",
        subject_selector_id: context.role, subject_repository_id: context.repository&.id }.compact
    end

    def deduplication_key(decision, fingerprint)
      subject = context.agent_actor || context.user
      [ "scheduled", subject.class.polymorphic_name, subject.id, decision.invocation.capability,
        decision.invocation.operation, fingerprint ].join(":")
    end

    def item_attributes(descriptor, decision, fingerprint)
      {
        kind: "operation", capability_version: version(decision.invocation.capability),
        operation_version: version(decision.invocation.operation), resource_type: descriptor.resource_scope.type.to_s,
        resource_scope: decision.invocation.resource_scope || {}, normalized_arguments: descriptor.redact(arguments),
        invocation_fingerprint: fingerprint, effects: decision.invocation.effects,
        policy_chain: decision.chain.map(&:to_h), decisive_rule: decision.decisive_rule&.to_h || {},
        requested_durations: descriptor.authority_durations
      }
    end

    def version(identifier) = identifier.to_s[/@v(\d+)\z/, 1].to_i

    def checkpoint!(request)
      request.checkpoint_authorization!(payload: {
        run_id: context.run.id, tool_name: McpToolRegistry.tool_name_for(tool),
        arguments: arguments, invocation_fingerprint: request.authorization_items.first.invocation_fingerprint
      })
    end
  end
end
