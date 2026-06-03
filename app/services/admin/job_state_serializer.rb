module Admin
  # Shared JSON shape for the Workflow → Step → Run subtree.
  # Used by `Api::V1::Admin::JobsController#show` (one Job, all
  # workflows nested) and `Api::V1::Admin::WorkflowsController#show`
  # (one workflow, no siblings).
  #
  # Per-record resilience: every method ends with `rescue => e`
  # that emits `{ id: ..., error_serializing: "..." }` instead of
  # propagating. A single bad row never 500s the whole nested
  # response. Failures are logged so the underlying bug isn't
  # silently swallowed.
  module JobStateSerializer
    module_function

    def workflow(wf)
      {
        id: wf.id,
        trigger_kind: wf.trigger_kind,
        agent_provider: wf.agent_provider,
        state: wf.state,
        failure_count: wf.failure_count,
        artifacts: wf.artifacts,
        cleaned_up_at: wf.cleaned_up_at,
        retry_available: wf.retry_available?,
        started_at: wf.started_at,
        finished_at: wf.finished_at,
        created_at: wf.created_at,
        updated_at: wf.updated_at,
        failure_classification: workflow_failure_classification(wf),
        steps: wf.steps.order(:position).map { |s| step(s) }
      }
    rescue => e
      per_record_error(wf, e)
    end

    def step(step)
      {
        id: step.id,
        kind: step.kind,
        position: step.position,
        iteration: step.iteration,
        state: step.state,
        started_at: step.started_at,
        finished_at: step.finished_at,
        created_at: step.created_at,
        updated_at: step.updated_at,
        details: step.details.presence,
        runs: step.runs.order(:created_at).map { |r| run(r) }
      }
    rescue => e
      per_record_error(step, e)
    end

    def run(run)
      session = run.claude_session
      session_payload = agent_session_payload(session)

      {
        id: run.id,
        state: run.state,
        trigger_kind: run.trigger_kind,
        agent_provider: run.agent_provider,
        agent_outcome: run.agent_outcome,
        agent_turns: run.agent_turns,
        agent_pr_title: run.agent_pr_title,
        parent_session_id: run.parent_session_id,
        head_sha: run.head_sha,
        started_at: run.started_at,
        last_heartbeat_at: run.last_heartbeat_at,
        finished_at: run.finished_at,
        created_at: run.created_at,
        updated_at: run.updated_at,
        agent_diff_present: run.agent_diff.present?,
        agent_diff_bytes: run.agent_diff&.bytesize || 0,
        job_log_count: run.job_logs.size,
        agent_session: session_payload,
        failure_classification: failure_classification(run.run_failure_classification),
        run_diagnostic: run.run_diagnostic && {
          error_class: run.run_diagnostic.error_class,
          error_message: run.run_diagnostic.error_message,
          created_at: run.run_diagnostic.created_at
        }
      }
    rescue => e
      per_record_error(run, e)
    end

    def agent_session_payload(session)
      return unless session

      {
        session_id: session.session_id,
        provider: session.provider,
        # transcript_jsonl is dropped on Run success (commit
        # 804cdf5) — keep the metadata visible but flag the
        # body as pruned instead of pretending size 0.
        transcript_pruned: session.transcript_jsonl.nil?,
        transcript_bytes:  session.transcript_jsonl&.bytesize,
        transcript_lines:  session.transcript_jsonl&.count("\n")
      }
    end

    def workflow_failure_classification(wf)
      run = wf.steps
              .flat_map { |step| step.runs.select(&:failed?) }
              .sort_by { |candidate| candidate.finished_at || candidate.updated_at || candidate.created_at }
              .last
      failure_classification(run&.run_failure_classification)
    end

    def failure_classification(classification)
      return unless classification

      {
        id: classification.id,
        classification: classification.classification,
        confidence: classification.confidence&.to_f,
        retryable: classification.retryable,
        reason: classification.reason,
        diagnostic_summary: classification.diagnostic_summary,
        classifier_inputs: classification.classifier_inputs,
        classified_at: classification.classified_at
      }
    end

    def per_record_error(record, error)
      Rails.logger.warn(
        "[admin/job_state_serializer] failed for #{record.class}##{record.id}: " \
        "#{error.class}: #{error.message}"
      )
      { id: record.id, error_serializing: "#{error.class}: #{error.message}" }
    end
  end
end
