require "mcp"

module Mcp::Tools
  # Called by a Coding Mode or Local Mode chat agent after it has committed and
  # pushed the implementation. Queues an operator confirmation before graders run.
  class CompleteImplementStepTool < MCP::Tool
    extend JobLifecycleToolSupport
    extend ProposalToolSupport

    tool_name "complete_implement_step"

    description <<~DESC
      Request operator confirmation that implementation is complete after the
      chat coding checkout or local daemon has committed and pushed changes to
      the branch. The handoff workflow for Syrus graders (and PR open if needed)
      is not enqueued until the operator confirms the pending action. Call this
      only after the operator explicitly instructs you to hand off, the working
      tree is clean, and the branch has been pushed to the remote.
    DESC

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id to hand off." },
        branch_name: {
          type: "string",
          description: "Branch name pushed to the remote. Required for Jobs without an existing PR; replaces the stored branch when supplied for a rerun."
        }
      },
      required: %w[job_id]
    )

    class << self
      def call(job_id:, branch_name: nil, server_context:)
        chat_session = server_context.fetch(:chat_session)
        job, error = find_repository_job(chat_session, job_id)
        return error if error
        normalized_branch = normalize_branch_name(branch_name)

        unless job.coding?
          return Mcp::Tools.invalid("#{job.slug} is not in coding state (current: #{job.state}).")
        end
        unless job.linked_chat_id == chat_session.id
          return Mcp::Tools.invalid("#{job.slug} is not linked to this chat session.")
        end
        unless chat_session.local? || chat_session.coding?
          return Mcp::Tools.invalid("complete_implement_step is only available in Coding Mode or Local Mode.")
        end
        if !chat_session.local? && !Feature.coding_mode_enabled?
          return Mcp::Tools.invalid("Coding Mode is not enabled.")
        end
        if job.pr_number.blank? && normalized_branch.blank?
          return Mcp::Tools.invalid("branch_name is required for Jobs without an existing PR.")
        end
        if normalized_branch.present? && !valid_branch_name?(normalized_branch)
          return Mcp::Tools.invalid("branch_name is not a valid branch name.")
        end

        payload = { "job_id" => job.id }
        payload["branch_name"] = normalized_branch if normalized_branch.present?
        pending_action = create_pending_action_for_current_message!(
          server_context,
          chat_session,
          action: "complete_implement_step",
          payload: payload,
          requested_by: "agent"
        )

        Mcp::Tools.success(
          pending_confirmation_id: pending_action.id,
          pending_action_id: pending_action.id,
          state: pending_action.state,
          message: "Implementation handoff requires operator confirmation."
        )
      rescue ActiveRecord::RecordInvalid => e
        invalid_record(e)
      end

      def normalize_branch_name(branch_name)
        branch_name.to_s.strip.presence
      end

      def valid_branch_name?(branch_name)
        return false if branch_name.start_with?("/", "-") || branch_name.end_with?("/", ".")
        return false if branch_name.include?("//") || branch_name.include?("..")
        return false if branch_name.end_with?(".lock")
        return false if branch_name.split("/").any? { |part| part.blank? || part.start_with?(".") }

        !branch_name.match?(/[[:space:]~^:?*\[\\]/)
      end
    end
  end
end
