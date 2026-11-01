module Permissions
  class CoworkerAuthorizationDecision
    Result = Data.define(:request, :execution_enqueued)

    def initialize(request:, item:, user:)
      @request = request
      @item = item
      @user = user
    end

    def call(decision:)
      raise ArgumentError, "not a coworker authorization request" unless request.authorization_request? && request.action == "coworker_tool_call"
      raise ActiveRecord::RecordNotFound, "authorization request belongs to another user" unless request.user == user
      raise ArgumentError, "authorization item belongs to another request" unless item.chat_pending_action_id == request.id

      decision = decision.to_s
      raise ArgumentError, "decision must be approved or denied" unless decision.in?(%w[approved denied])

      ready = request.with_lock do
        return Result.new(request:, execution_enqueued: false) unless request.pending? && item.reload.actionable?

        if decision == "denied"
          item.decide!(decision, principal: user)
          request.authorization_items.pending.where.not(id: item.id).find_each do |pending|
            pending.mark_non_actionable!("Another authorization prerequisite was denied")
          end
          request.update!(state: "rejected", rejected_at: Time.current)
          return Result.new(request:, execution_enqueued: false)
        end

        item.decide!(decision, principal: user, duration: "invocation")
        issue_invocation!(item) if item.kind == "operation"
        request.reload.ready_for_authorized_invocation?
      end
      enqueued = ready && request.enqueue_confirmation!(user: user)
      Result.new(request:, execution_enqueued: enqueued)
    end

    private

    attr_reader :request, :item, :user

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
