require "mcp"

module Mcp::Tools
  class WithdrawPendingActionTool < MCP::Tool
    tool_name "withdraw_pending_action"

    description <<~DESC
      Immediately withdraw an unconfirmed pending action created in this chat.
      Pending actions are rejected and queued or otherwise cancellable actions
      are cancelled. Identify it by action and optional Job target, or omit all
      selectors when this chat has exactly one withdrawable action. Use the
      numeric ID only as an exact handle when semantic selectors are ambiguous.
      This never creates another confirmation request.
    DESC

    input_schema(
      properties: {
        pending_action_id: { type: "integer", description: "ID of the pending action to withdraw." },
        action: { type: "string", description: "Tool/action name of the pending action to withdraw." },
        job_id: { type: "integer", description: "Job target used to distinguish otherwise similar actions." },
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
        owned_actions = chat_session.pending_actions.where(user_id: chat_session.user_id)
        if pending_action_id.present?
          id = Integer(pending_action_id, exception: false)
          found = owned_actions.find_by(id: id) if id
          return found || Mcp::Tools.invalid("pending action not found in this chat")
        end

        scope = owned_actions.where(state: %w[pending queued])
        scope = scope.where(action: action.to_s) if action.present?
        if job_id.present?
          normalized_job_id = Integer(job_id, exception: false)
          return Mcp::Tools.invalid("job_id must be an integer") unless normalized_job_id
          scope = scope.select { |candidate| targets_job?(candidate, normalized_job_id) }
        else
          scope = scope.to_a
        end

        return scope.first if scope.one?
        return Mcp::Tools.invalid("no matching withdrawable pending action was found in this chat") if scope.empty?

        candidates = scope.map { |candidate| candidate_summary(candidate) }.join("; ")
        Mcp::Tools.invalid("more than one pending action matches; distinguish it by action and target: #{candidates}")
      end

      def targets_job?(candidate, job_id)
        payload = candidate.payload.to_h
        payload["job_id"].to_i == job_id || Array(payload["job_ids"]).map(&:to_i).include?(job_id)
      end

      def candidate_summary(candidate)
        payload = candidate.payload.to_h
        target = if payload["job_id"].present?
          "JOB-#{payload['job_id']}"
        elsif payload["job_ids"].present?
          Array(payload["job_ids"]).map { |id| "JOB-#{id}" }.join(", ")
        else
          "this chat"
        end
        reason = candidate.reason.presence || payload["reason"].presence || payload["message"].presence || candidate.purpose.presence || "no reason provided"
        "#{candidate.action.presence || candidate.action_type} for #{target} (reason: #{ToolPayloadRedactor.redact_text(reason.to_s).truncate(200)})"
      end
    end
  end
end
