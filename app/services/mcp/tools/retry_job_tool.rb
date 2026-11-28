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
      Modes are: auto (selects the canonical recovery operation), failed_step
      (resume/rerun/repair on the same source snapshot), implementation (an
      explicit fresh implementation attempt from the
      effective base), and refresh_base (checkpoint-aware base refresh).
      Measured failures and no-progress stops require context with specific
      repair guidance; without it the tool returns guidance_required and does
      not create a pending action. Infrastructure-only no-verdict outcomes may
      rerun unchanged, interrupted work resumes, and a fresh implementation
      restart must be explicitly requested. An explicitly requested implementation mode is an operator-confirmed
      escalation even when failed_step is the initial recommendation; it does
      not relax active-work, duplicate-retry, passing-PR, or landing gates.
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
        source_workflow_id: { type: "integer", description: "Optional failed Workflow to use for failed_step, or failed/strictly eligible blocked Workflow for refresh_base." },
        reason: { type: "string", description: "Required operator-facing audit reason for refresh_base." },
        context: {
          type: "string",
          description: "Operator guidance for the retrying agent (failed_step and implementation modes). failed_step adds it to the existing Workflow, so the next repair round on the current branch sees it; implementation gives it to the fresh attempt from the base."
        }
      }
    )

    class << self
      CONTEXT_MODES = %w[failed_step implementation].freeze

      def call(job_id: nil, job_ids: nil, mode: "auto", source_workflow_id: nil, reason: nil, context: nil, server_context:)
        context = context.to_s.strip.presence
        if context && !CONTEXT_MODES.include?(mode.to_s)
          return Mcp::Tools.invalid("context is supported only for the #{CONTEXT_MODES.join(' and ')} modes")
        end

        chat_session = server_context.fetch(:chat_session)
        ids, bulk, error = resolve_ids(id: job_id, ids: job_ids, param_name: "job_id")
        return error if error

        jobs = ids.map { |id| find_job!(id) }
        selection = RetryJobs::Selection.call(jobs)
        return Mcp::Tools.invalid(selection.error) unless selection.success?
        jobs = selection.jobs

        if mode.to_s == "auto"
          legacy_preflights = jobs.to_h { |job| [ job.id, RetryJobs::Modes::Auto.new(job:).preflight ] }
          legacy_ineligible = jobs.filter_map do |job|
            result = legacy_preflights.fetch(job.id)
            "#{job.slug}: #{result.message}" unless result.eligible?
          end
          return Mcp::Tools.invalid("Cannot retry #{legacy_ineligible.size} of #{jobs.size} Jobs - #{legacy_ineligible.join('; ')}") if legacy_ineligible.any?
        end

        recoveries = jobs.to_h do |job|
          source = recovery_source_workflow(job, source_workflow_id)
          decision = RecoveryDecision.for(job:, workflow: source)
          effective_mode = if mode.to_s == "auto" && decision.kind == "restart_from_base" && decision.evidence[:source_step_id].blank?
            "auto"
          elsif mode.to_s == "auto"
            decision.mode
          else
            mode.to_s
          end
          [ job.id, { job:, source:, decision:, effective_mode: } ]
        end
        explicit_restart_required = recoveries.values.select do |recovery|
          mode.to_s == "auto" && recovery[:effective_mode].in?(%w[implementation restart])
        end
        if explicit_restart_required.any?
          return Mcp::Tools.invalid("Fresh implementation restart must be explicit; inspect recovery and call retry_job with mode: implementation.")
        end

        guidance_needed = recoveries.values.select do |recovery|
          recovery[:decision].recommended_action == "repair_with_guidance" &&
            recovery[:effective_mode] == "failed_step" &&
            context.blank?
        end
        if guidance_needed.any?
          return Mcp::Tools.success(
            status: "guidance_required",
            persistent_failures: bounded_failure_identities(guidance_needed),
            suggested_guidance: guidance_needed.first[:decision].guidance,
            recoveries: guidance_needed.map { |recovery| recovery_decision_payload(recovery) },
            pending_action_created: false
          )
        end

        preflights = jobs.to_h do |job|
          recovery = recoveries.fetch(job.id)
          mode_class = RetryJobs::Mode.for(recovery[:effective_mode])
          mode_arguments = { job: job, source_workflow_id: recovery[:source]&.id, reason: reason }
          mode_arguments[:explicit_operator_intent] = true if recovery[:effective_mode] == "implementation"
          [ job.id, mode_class.new(**mode_arguments).preflight ]
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
            payload: retry_payload(job, recoveries.fetch(job.id), reason, preflights.fetch(job.id), selected_job_ids, context),
            requested_by: "agent"
          )

          autonomous = AuthorizationSupport.complete_autonomous_pending_action!(pending_action, server_context, job:)

          return Mcp::Tools.success(
            pending_action_id: pending_action.id,
            state: pending_action.reload.state,
            message: autonomous ? "Job retry started." : (mode.to_s == "auto" ? "Job retry requires operator confirmation." : "#{mode.to_s.humanize} Job retry requires operator confirmation."),
            recovery: recovery_decision_payload(recoveries.fetch(job.id)),
            preflight: preflights.fetch(job.id).details
          )
        end

        group = create_pending_action_group!(
          server_context: server_context,
          chat_session: chat_session,
          member_attributes: jobs.map do |job|
            { action: "retry_job", payload: retry_payload(job, recoveries.fetch(job.id), reason, preflights.fetch(job.id), selected_job_ids, context), requested_by: "agent" }
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

      def retry_payload(job, recovery, reason, preflight, selected_job_ids, context = nil)
        mode = recovery[:effective_mode]
        decision = recovery[:decision]
        source_workflow_id = recovery[:source]&.id
        if mode == "auto" && decision.evidence[:source_step_id].blank?
          payload = { "job_id" => job.id }
          payload["context"] = context if context.present?
          return payload
        end
        payload = {
          "job_id" => job.id,
          "mode" => mode,
          "recovery_kind" => decision.kind,
          "recovery_action" => decision.recommended_action,
          "source_failure_classification" => decision.evidence[:failure_classification]
        }.compact
        payload["context"] = context if context.present?
        payload["source_workflow_id"] = preflight.details["source_workflow_id"] || source_workflow_id if source_workflow_id.present? || preflight.details["source_workflow_id"]
        payload["reason"] = reason.to_s.strip if reason.present?
        payload["preflight"] = preflight.details if preflight.details.present?
        if mode.to_s == "refresh_base"
          payload["selected_upstream_job_ids"] = RetryJobs::Selection.selected_upstream_ids(job, selected_job_ids)
        end
        payload
      end

      def recovery_source_workflow(job, source_workflow_id)
        scope = job.workflows.where(state: %w[failed blocked cancelled])
        source_workflow_id.present? ? scope.find_by(id: source_workflow_id) : scope.reorder(created_at: :desc, id: :desc).first
      end

      def recovery_decision_payload(recovery)
        RecoveryContract.for_job(recovery[:job], workflow: recovery[:source])[:decision]
      end

      def bounded_failure_identities(recoveries)
        recoveries.flat_map { |recovery| Array(recovery[:decision].evidence[:measured_failure_identities]) }
          .uniq.first(RecoveryContract::FAILURE_LIMIT)
          .filter_map { |failure| failure.to_s.each_char.first(RecoveryContract::TEXT_LIMIT).join.presence }
      end
    end
  end
end
