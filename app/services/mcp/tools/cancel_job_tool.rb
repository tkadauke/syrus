require "mcp"

module Mcp::Tools
  class CancelJobTool < MCP::Tool
    extend ProposalToolSupport
    extend BulkPendingActionToolSupport
    extend AuthorizationSupport
    singleton_class.prepend(AuthorizationSupport::ToolDispatch)

    tool_name "cancel_job"

    description <<~DESC
      Request cancellation of one or more Syrus Jobs in this repository. Pass
      Eligible states are
      #{Mcp::ControlToolContracts.states(JobCancellationEligibility::ELIGIBLE_STATES)};
      a closed Job is already terminal and must be reopened before further work.
      job_id for a single Job (unchanged single-confirmation behavior) or
      job_ids for multiple Jobs, which creates one grouped pending action the
      operator confirms or rejects together. The Job(s) are not cancelled
      until confirmation. The call creates only pending action(s); confirmation
      cancels active Runs/Workflows and closes each Job, without creating a Job,
      Workflow, or WorkUnit or entering admission control/the worker queue.
    DESC

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id to cancel." },
        job_ids: {
          type: "array",
          items: { type: "integer" },
          description: "Multiple Syrus Job ids to cancel as one grouped pending action."
        }
      }
    )

    class << self
      def call(job_id: nil, job_ids: nil, server_context:)
        chat_session = server_context.fetch(:chat_session)
        ids, bulk, error = resolve_ids(id: job_id, ids: job_ids, param_name: "job_id")
        return error if error

        jobs = ids.map { |id| find_job!(id) }
        ineligible = jobs.filter_map do |job|
          eligibility = JobCancellationEligibility.call(job: job)
          "#{job.slug}: #{eligibility.message}" unless eligibility.eligible?
        end
        if ineligible.any?
          return Mcp::Tools.invalid("Cannot cancel #{ineligible.size} of #{jobs.size} Jobs - #{ineligible.join('; ')}")
        end

        unless bulk
          job = jobs.first
          pending_action = create_pending_action_for_current_message!(
            server_context,
            chat_session,
            action: "cancel_job",
            payload: { "job_id" => job.id },
            requested_by: "agent"
          )

          return Mcp::Tools.success(
            pending_confirmation_id: pending_action.id,
            pending_action_id: pending_action.id,
            state: pending_action.state,
            message: "Job cancellation requires operator confirmation."
          )
        end

        group = create_pending_action_group!(
          server_context: server_context,
          chat_session: chat_session,
          member_attributes: jobs.map { |job| { action: "cancel_job", payload: { "job_id" => job.id }, requested_by: "agent" } }
        )
        bulk_action_response(group: group, message: "Cancel #{jobs.size} Jobs?")
      rescue ActiveRecord::RecordInvalid => e
        Mcp::Tools.invalid(e.record.errors.full_messages.to_sentence)
      end
    end
  end
end
