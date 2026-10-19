require "mcp"

module Mcp::Tools
  # Called by a Coding Mode chat agent only after the operator explicitly asks
  # for the emergency-land escape hatch in the current turn. Queues an operator
  # confirmation; the actual landing happens only after confirmation.
  class EmergencyLandTool < MCP::Tool
    extend JobLifecycleToolSupport
    extend ProposalToolSupport

    tool_name "emergency_land"

    description <<~DESC
      For the Job already linked to this Coding Mode chat, request
      an emergency landing. The Job must be in `coding`, the caller must have
      repository-admin permission, and the emergency_land feature must be on.
      This creates only a pending action: no Job, Workflow, or WorkUnit is
      created and nothing enters admission control or the worker queue. If the
      operator confirms, Syrus rechecks every precondition, records the supplied
      already-pushed branch on that same Job (or uses its recorded branch), then
      opens a PR if needed and asks GitHub to merge it directly. It cannot land
      an arbitrary captured or local-only branch. It does not require or read
      the current local checkout; linkage and the pushed Job branch are the
      controlling preconditions. Confirmation skips Syrus's
      grader, adversarial-review, and visual-review pipeline. This is not a normal
      handoff path. Call it ONLY when the operator has explicitly and
      unambiguously asked for an emergency or urgent land in this turn, such as
      "emergency land this now" or "skip review and land". Never call this
      proactively -- not because graders are slow, not because tests are
      failing, and not because you inferred urgency yourself. If the operator
      has not said this explicitly in this turn, use complete_implement_step or
      submit_coding_changes instead.
    DESC

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id to emergency land." },
        branch_name: {
          type: "string",
          description: "Already-pushed branch to land. Required when the Job does not already have a branch recorded; replaces the stored branch only after operator confirmation."
        }
      },
      required: %w[job_id]
    )

    class << self
      def call(job_id:, branch_name: nil, server_context:)
        chat_session = server_context.fetch(:chat_session)
        job, error = find_job(job_id)
        return error if error

        normalized_branch = GitBranchName.normalize(branch_name)
        validation_error = validate_request(chat_session: chat_session, job: job, branch_name: normalized_branch)
        return validation_error if validation_error

        existing_action = pending_landing_action_for(chat_session, job)
        if existing_action
          return pending_action_response(existing_action) if existing_action.action == "emergency_land"

          return Mcp::Tools.invalid("A complete_implement_step confirmation is already pending for #{job.slug}; resolve it before requesting emergency_land.")
        end

        payload = {
          "chat_session_id" => chat_session.id,
          "job_id" => job.id,
          "branch_name" => normalized_branch.presence || job.branch_name
        }
        pending_action = create_pending_action_for_current_message!(
          server_context,
          chat_session,
          action: "emergency_land",
          payload: payload,
          requested_by: "agent"
        )

        pending_action_response(pending_action)
      rescue ActiveRecord::RecordInvalid => e
        invalid_record(e)
      end

      private

      def find_job(job_id)
        normalized_id = Integer(job_id, exception: false)
        return [ nil, Mcp::Tools.invalid("job_id is required") ] unless normalized_id

        job = Job.find_by(id: normalized_id)
        return [ nil, Mcp::Tools.invalid("job not found: #{normalized_id}") ] unless job

        [ job, nil ]
      end

      def validate_request(chat_session:, job:, branch_name:)
        eligibility = EmergencyLand::Eligibility.call(chat_session: chat_session, job: job, branch_name: branch_name)
        Mcp::Tools.invalid(eligibility.message) unless eligibility.eligible?
      end

      def pending_landing_action_for(chat_session, job)
        chat_session.pending_actions
          .where(action: %w[complete_implement_step emergency_land])
          .where(state: %w[queued pending confirming failed])
          .detect { |action| action.payload.to_h["job_id"].to_i == job.id }
      end

      def pending_action_response(pending_action)
        Mcp::Tools.success(
          pending_confirmation_id: pending_action.id,
          pending_action_id: pending_action.id,
          state: pending_action.state,
          message: "Emergency land requires operator confirmation."
        )
      end
    end
  end
end
