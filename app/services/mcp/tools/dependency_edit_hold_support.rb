module Mcp::Tools
  # `hold_running: true` on the dependency tools. Cancelling a Job's running
  # work is always the confirmed `hold_job` pending action, under the same
  # authority (the Job's owner, or an admin for any Job). The edit is not
  # applied now: the pending action carries it, and confirmation applies it
  # and holds the Job in one transaction.
  module DependencyEditHoldSupport
    include ProposalToolSupport

    private

    def request_hold_for_dependency_edit(server_context:, job:, tool_name:, arguments:, reason:)
      user = server_context.fetch(:chat_session).user
      unless user.admin? || job.user_id == user.id
        return Mcp::Tools.invalid("Holding #{job.slug}'s running work requires owning the Job (or an admin).")
      end

      edit = { "tool" => tool_name, "arguments" => arguments.compact.deep_stringify_keys }
      pending_action = create_pending_action_for_current_message!(
        server_context,
        server_context.fetch(:chat_session),
        action: "hold_job",
        payload: { "job_id" => job.id, "to_backlog" => false, "dependency_edit" => edit },
        reason: reason.to_s.strip.presence || "Hold #{job.slug} to apply a #{tool_name} edit",
        requested_by: "agent"
      )
      Mcp::Tools.success(
        pending_action_id: pending_action.id,
        state: pending_action.state,
        job_id: job.id,
        message: I18n.t("server.mcp.hold_job_confirmation.message", job: job.slug)
      )
    rescue ActiveRecord::RecordInvalid => e
      Mcp::Tools.invalid(e.record.errors.full_messages.to_sentence)
    end
  end
end
