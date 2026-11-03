module Permissions
  class CoworkerAuthorizationDecision
    Result = Data.define(:request, :execution_enqueued)

    def initialize(request:, item:, user:)
      @request = request
      @item = item
      @user = user
    end

    def call(decision:, smart: nil)
      raise ArgumentError, "not a coworker authorization request" unless request.authorization_request? && request.action.in?(SmartDecision::SUPPORTED_ACTIONS)
      raise ActiveRecord::RecordNotFound, "authorization request belongs to another user" unless request.user == user
      raise ArgumentError, "authorization item belongs to another request" unless item.chat_pending_action_id == request.id

      decision = decision.to_s
      raise ArgumentError, "decision must be approved or denied" unless decision.in?(%w[approved denied])

      raise ArgumentError, "a rule can only accompany an approval" if smart && decision != "approved"
      permission_request = request.action == CoworkerPermissionRequest::ACTION
      if permission_request && decision == "approved" && smart.nil?
        raise ArgumentError, I18n.t("api.permission_requests.smart_decision.duration_required")
      end

      ready = request.with_lock do
        unless request.pending? && item.reload.actionable?
          raise SmartDecision::AlreadyDecided, I18n.t("api.permission_requests.smart_decision.stale") if smart

          return Result.new(request:, execution_enqueued: false)
        end

        if decision == "denied"
          item.decide!(decision, principal: user)
          request.authorization_items.pending.where.not(id: item.id).find_each do |pending|
            pending.mark_non_actionable!("Another authorization prerequisite was denied")
          end
          request.update!(state: "rejected", rejected_at: Time.current)
          audit(:coworker_permission_request_denied)
          return Result.new(request:, execution_enqueued: false)
        end

        # The rule (or lease) and the approval share this transaction: a stale
        # preview, ceiling or failed invocation rolls back both.
        rule = SmartDecision.new(request:, item:, user:).apply_rule!(duration: smart.fetch(:duration), digest: smart[:digest]) if smart
        item.decide!(decision, principal: user, duration: smart ? smart.fetch(:duration) : "invocation", resulting_authority: rule)
        if permission_request
          # Nothing is waiting to run: the approval is the rule or lease itself.
          request.update!(state: "confirmed")
          audit(:coworker_permission_granted, authority: SmartDecision.authority_reference(item), duration: smart.fetch(:duration))
          return Result.new(request:, execution_enqueued: false)
        end
        issue_invocation!(item) if item.kind == "operation"
        request.reload.ready_for_authorized_invocation?
      end
      enqueued = ready && request.enqueue_confirmation!(user: user)
      Result.new(request:, execution_enqueued: enqueued)
    end

    private

    attr_reader :request, :item, :user

    def audit(event, **details)
      return unless request.action == CoworkerPermissionRequest::ACTION && request.subject

      CoworkerAudit.record!(event, owner: user, coworker: request.subject, authorization_request_id: request.id,
        capability: item.capability, operation: item.operation, **details)
    end

    def issue_invocation!(operation)
      descriptor = permission_descriptor
      arguments = request.payload.fetch("arguments")
      authority = Management.new(user).grant_authority!(
        duration: :invocation, descriptor:, actor: user,
        subject_selector_type: "agent", subject_selector_id: request.subject_id,
        subject_repository: request.repository, role: request.runtime_role,
        resource_scope: operation.resource_scope, arguments:,
        context: evaluation_context, source: request
      )
      AuthorizedInvocation.issue!(
        pending_action_item: operation, authority:, tool_name: request.payload.fetch("tool_name"),
        execution_authority: evaluation_context, audit_payload: { pending_action_id: request.id }
      )
    end

    def permission_descriptor
      catalog_entry = Mcp::CoworkerToolCatalog.resolve(request.payload.fetch("tool_name"), chat_session: request.chat_session)
      raise ArgumentError, "tool is not available to coworkers" unless catalog_entry

      if catalog_entry.tool
        McpToolRegistry.entries(surface: :coworker).find { |entry| entry.tool == catalog_entry.tool }&.descriptor
      else
        CapabilityDescriptorAdapter.for_plugin_definition(catalog_entry.definition)
      end || raise(ArgumentError, "tool has no permission descriptor")
    end

    def evaluation_context
      {
        role: request.runtime_role,
        agent_id: request.subject_id,
        subject_selector_type: "agent",
        subject_selector_id: request.subject_id.to_s,
        subject_repository_id: request.repository_id,
        chat_session_id: request.chat_session_id,
        job_id: (request.origin_id if request.origin_type == "Job")
      }.compact
    end
  end
end
