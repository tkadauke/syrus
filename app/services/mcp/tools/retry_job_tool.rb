require "mcp"

module Mcp::Tools
  class RetryJobTool < MCP::Tool
    extend ProposalToolSupport
    extend BulkPendingActionToolSupport
    extend AuthorizationSupport
    singleton_class.prepend(AuthorizationSupport::ToolDispatch)

    tool_name "retry_job"

    description <<~DESC
      Request a retry workflow for one or more Syrus Jobs in this repository.
      Candidate Job states are
      #{Mcp::ControlToolContracts.states(RetryWorkflowEligibility::CANDIDATE_JOB_STATES)};
      the shared eligibility predicate also rejects a current passing PR, active
      Run, duplicate retry, superseded retry, landing failure, or an initial
      Workflow that has never run, and its error names the valid next action.
      Pass job_id for a single Job (unchanged single-confirmation behavior)
      or job_ids for multiple Jobs, which creates one grouped pending action
      the operator confirms or rejects together. The call creates pending
      action(s), not Jobs, Workflows, or WorkUnits. On
      confirmation, it creates a retry Workflow/WorkUnit and submits it through
      normal admission control and worker-queue routing.
      Modes are: auto (compatible smart retry), failed_step (same source
      snapshot), implementation (fresh implementation attempt from the
      effective base), and refresh_base (checkpoint-aware base refresh).
    DESC

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id to retry." },
        job_ids: {
          type: "array",
          items: { type: "integer" },
          description: "Multiple Syrus Job ids to retry as one grouped pending action."
        },
        mode: { type: "string", enum: RetryJobs::Mode::MODES.keys, description: "Retry mode (defaults to auto)." },
        source_workflow_id: { type: "integer", description: "Optional failed Workflow to use for failed_step or refresh_base." },
        reason: { type: "string", description: "Required operator-facing audit reason for refresh_base." }
      }
    )

    class << self
      def call(job_id: nil, job_ids: nil, mode: "auto", source_workflow_id: nil, reason: nil, server_context:)
        chat_session = server_context.fetch(:chat_session)
        ids, bulk, error = resolve_ids(id: job_id, ids: job_ids, param_name: "job_id")
        return error if error

        jobs = ids.map { |id| find_job!(id) }
        selection = RetryJobs::Selection.call(jobs)
        return Mcp::Tools.invalid(selection.error) unless selection.success?
        jobs = selection.jobs

        mode_class = RetryJobs::Mode.for(mode)
        preflights = jobs.to_h do |job|
          result = mode_class.new(job: job, source_workflow_id: source_workflow_id, reason: reason).preflight
          [ job.id, result ]
        end
        selected_job_ids = jobs.map(&:id)
        ineligible = jobs.filter_map do |job|
          result = preflights.fetch(job.id)
          "#{job.slug}: #{result.message}" unless result.eligible?
        end
        return Mcp::Tools.invalid("Cannot retry #{ineligible.size} of #{jobs.size} Jobs - #{ineligible.join('; ')}") if ineligible.any?

        unless bulk
          job = jobs.first
          pending_action = create_pending_action_for_current_message!(
            server_context,
            chat_session,
            action: "retry_job",
            payload: retry_payload(job, mode, source_workflow_id, reason, preflights.fetch(job.id), selected_job_ids),
            requested_by: "agent"
          )

          return Mcp::Tools.success(
            pending_confirmation_id: pending_action.id,
            pending_action_id: pending_action.id,
            state: pending_action.state,
            message: mode.to_s == "auto" ? "Job retry requires operator confirmation." : "#{mode.to_s.humanize} Job retry requires operator confirmation.",
            preflight: preflights.fetch(job.id).details
          )
        end

        group = create_pending_action_group!(
          server_context: server_context,
          chat_session: chat_session,
          member_attributes: jobs.map do |job|
            { action: "retry_job", payload: retry_payload(job, mode, source_workflow_id, reason, preflights.fetch(job.id), selected_job_ids), requested_by: "agent" }
          end,
          reason: reason.to_s.strip.presence
        )
        message = mode.to_s == "auto" ? "Retry #{jobs.size} Jobs?" : "#{mode.to_s.humanize} retry #{jobs.size} Jobs?"
        bulk_action_response(group: group, message: message,
          extra: { mode: mode, preflight: jobs.map { |job| { job_id: job.id, job_slug: job.slug, **preflights.fetch(job.id).details } } })
      rescue ArgumentError => e
        Mcp::Tools.invalid(e.message)
      rescue ActiveRecord::RecordInvalid => e
        Mcp::Tools.invalid(e.record.errors.full_messages.to_sentence)
      end

      private

      def retry_payload(job, mode, source_workflow_id, reason, preflight, selected_job_ids)
        payload = { "job_id" => job.id }
        payload["mode"] = mode.to_s unless mode.to_s == "auto"
        payload["source_workflow_id"] = preflight.details["source_workflow_id"] || source_workflow_id if source_workflow_id.present? || preflight.details["source_workflow_id"]
        payload["reason"] = reason.to_s.strip if reason.present?
        payload["preflight"] = preflight.details if preflight.details.present?
        if mode.to_s == "refresh_base"
          payload["selected_upstream_job_ids"] = RetryJobs::Selection.selected_upstream_ids(job, selected_job_ids)
        end
        payload
      end
    end
  end
end
