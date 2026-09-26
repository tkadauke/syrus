require "mcp"

module Mcp::Tools
  # Called by a Coding Mode or Local Mode chat agent after it has committed the
  # implementation. Queues an operator confirmation before graders run.
  class CompleteImplementStepTool < MCP::Tool
    extend JobLifecycleToolSupport
    extend ProposalToolSupport

    tool_name "complete_implement_step"

    description <<~DESC
      Request operator confirmation that implementation is complete. In Coding
      Mode, call this after committing in the chat coding checkout; do not push
      the Job branch to GitHub yourself. In Local Mode, the external daemon is
      responsible for pushing the branch when that workflow requires it. The
      handoff workflow for Syrus graders (and PR open if needed) is not enqueued
      until the operator confirms the pending action. Call this only after the
      operator explicitly instructs you to hand off and the working tree is clean.
    DESC

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id to hand off." },
        branch_name: {
          type: "string",
          description: "Branch name to hand off. Required for Jobs without an existing PR; replaces the stored branch when supplied for a rerun. In Coding Mode this names the local checkout branch, not a branch you pushed yourself."
        }
      },
      required: %w[job_id]
    )

    class << self
      def call(job_id:, branch_name: nil, server_context:)
        chat_session = server_context.fetch(:chat_session)
        job, error = find_repository_job(chat_session, job_id)
        return error if error
        normalized_branch = GitBranchName.normalize(branch_name)

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
        if normalized_branch.present? && !GitBranchName.valid?(normalized_branch)
          return Mcp::Tools.invalid("branch_name is not a valid branch name.")
        end
        existing_emergency_land = pending_landing_action_for(chat_session, job, action: "emergency_land")
        if existing_emergency_land
          return Mcp::Tools.invalid("An emergency_land confirmation is already pending for #{job.slug}; resolve it before requesting complete_implement_step.")
        end
        existing_handoff = pending_landing_action_for(chat_session, job, action: "complete_implement_step")
        return pending_action_response(existing_handoff) if existing_handoff

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

      private

      def pending_landing_action_for(chat_session, job, action:)
        chat_session.pending_actions
          .where(action: action)
          .where(state: %w[queued pending confirming failed])
          .detect { |pending_action| pending_action.payload.to_h["job_id"].to_i == job.id }
      end

      def pending_action_response(pending_action)
        Mcp::Tools.success(
          pending_confirmation_id: pending_action.id,
          pending_action_id: pending_action.id,
          state: pending_action.state,
          message: "Implementation handoff requires operator confirmation."
        )
      end
    end
  end
end
