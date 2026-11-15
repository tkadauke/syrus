require "mcp"

module Mcp::Tools
  class WithdrawPendingActionTool < MCP::Tool
    tool_name "withdraw_pending_action"

    description <<~DESC
      Immediately withdraw an unconfirmed pending action created in this chat.
      Pending actions are rejected and queued or otherwise cancellable actions
      are cancelled. Identify it by action and optional Job, or omit selectors
      when this chat has exactly one pending action. Use the numeric ID only as
      an exact internal handle when semantic selectors are ambiguous; never
      quote that handle to the operator. This never creates another
      confirmation request.
    DESC

    input_schema(
      properties: {
        pending_action_id: { type: "integer", description: "Exact internal handle for an ambiguous pending action." },
        action: { type: "string", description: "Tool/action name, such as retry_job or cancel_job." },
        job_id: { type: "integer", description: "Only consider actions targeting this Job." },
        reason: { type: "string", maxLength: 500, description: "Optional concise reason for withdrawing it." }
      }
    )

    class << self
      def call(server_context:, pending_action_id: nil, action: nil, job_id: nil, reason: nil)
        chat_session = server_context.fetch(:chat_session)
        pending_action = resolve_action(chat_session, pending_action_id:, action:, job_id:)
        return pending_action unless pending_action.is_a?(ChatPendingAction)

        result = PendingActions::Withdrawal.new(pending_action, user: chat_session.user, reason: reason).call
        Mcp::Tools.success(result.to_h)
      rescue PendingActions::Withdrawal::GroupedAction, PendingActions::Withdrawal::NotWithdrawable => e
        Mcp::Tools.invalid(e.message)
      rescue ActiveRecord::RecordNotFound
        Mcp::Tools.invalid("pending action not found in this chat")
      rescue ActiveRecord::RecordInvalid => e
        Mcp::Tools.invalid(e.record.errors.full_messages.to_sentence)
      end

      private

      def resolve_action(chat_session, pending_action_id:, action:, job_id:)
        actions = chat_session.pending_actions.where(user_id: chat_session.user_id)
        if pending_action_id.present?
          id = Integer(pending_action_id, exception: false)
          return Mcp::Tools.invalid("pending action not found in this chat") unless id

          return actions.find_by(id:) || Mcp::Tools.invalid("pending action not found in this chat")
        end

        actions = actions.where(state: "pending")
        actions = actions.where(action:) if action.present?
        if job_id.present?
          normalized_job_id = Integer(job_id, exception: false)
          return Mcp::Tools.invalid("job_id must be an integer") unless normalized_job_id

          actions = actions.select { |candidate| targets_job?(candidate, normalized_job_id) }
        else
          actions = actions.to_a
        end
        return actions.first if actions.one?
        return Mcp::Tools.invalid("no matching pending action was found in this chat") if actions.empty?

        candidates = actions.map { |candidate| candidate_summary(candidate) }.join("; ")
        Mcp::Tools.invalid("more than one pending action matches; distinguish it by action and target: #{candidates}")
      end

      def targets_job?(pending_action, job_id)
        payload = pending_action.payload.to_h
        payload["job_id"].to_i == job_id || Array(payload["job_ids"]).map(&:to_i).include?(job_id)
      end

      def candidate_summary(pending_action)
        payload = pending_action.payload.to_h
        reason = pending_action.reason.presence || payload["reason"].presence || payload["message"].presence || pending_action.purpose.presence
        summary = [ "action: #{pending_action.action.presence || pending_action.action_type}", target_summary(payload) ]
        summary << "reason: #{ToolPayloadRedactor.redact_text(reason.to_s).truncate(200)}" if reason
        summary.compact.join(", ")
      end

      def target_summary(payload)
        return "target: JOB-#{payload['job_id']}" if payload["job_id"].present?
        return "target: EPIC-#{payload['epic_id']}" if payload["epic_id"].present?
        return "target: Jobs #{Array(payload['job_ids']).map { |id| "JOB-#{id}" }.join(', ')}" if payload["job_ids"].present?

        "target: this chat"
      end
    end
  end
end
