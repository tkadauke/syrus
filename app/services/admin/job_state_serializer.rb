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

    RUN_COLUMNS = %i[
      id job_id step_id state trigger_kind agent_provider agent_outcome agent_turns
      agent_pr_title parent_session_id skill_source skill_resolved_path skill_resolved_class
      head_sha started_at last_heartbeat_at finished_at created_at updated_at
    ].freeze

    def workflow(wf, verbose: false)
      steps = wf.steps.sort_by(&:position)
      runs_by_step_id = projected_runs_for(steps)
      runs = runs_by_step_id.values.flatten
      run_metadata = run_metadata_for(runs)
      payload = {
        id: wf.id,
        trigger_kind: wf.trigger_kind,
        agent_provider: wf.agent_provider,
        state: wf.state,
        failure_count: wf.failure_count,
        cleaned_up_at: wf.cleaned_up_at,
        retry_available: wf.retry_available?,
        started_at: wf.started_at,
        finished_at: wf.finished_at,
        created_at: wf.created_at,
        updated_at: wf.updated_at,
        failure_classification: workflow_failure_classification(runs, verbose: verbose),
        steps: steps.map { |s| step(s, runs: runs_by_step_id.fetch(s.id, []), verbose: verbose, run_metadata: run_metadata) }
      }
      if verbose
        payload[:artifacts] = wf.artifacts
        payload[:landing_throughput_metrics] = wf.artifact(LandingThroughputMetrics::ARTIFACT_KEY)
      end
      payload
    rescue => e
      per_record_error(wf, e)
    end

    def step(step, runs: nil, verbose: false, run_metadata: {})
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
        runs: (runs || step.runs).sort_by(&:created_at).map { |r| run(r, verbose: verbose, metadata: run_metadata[r.id] || {}) }
      }
    rescue => e
      per_record_error(step, e)
    end

    def run(run, verbose: false, metadata: {})
      agent_diff_bytes = metadata.fetch(:agent_diff_bytes, 0)
      step_agent_diff_bytes = metadata.fetch(:step_agent_diff_bytes, 0)
      {
        id: run.id,
        state: run.state,
        trigger_kind: run.trigger_kind,
        agent_provider: run.agent_provider,
        agent_outcome: run.agent_outcome,
        agent_turns: run.agent_turns,
        agent_pr_title: run.agent_pr_title,
        parent_session_id: run.parent_session_id,
        skill_source: run.skill_source,
        skill_resolved_path: run.skill_resolved_path,
        skill_resolved_class: run.skill_resolved_class,
        head_sha: run.head_sha,
        started_at: run.started_at,
        last_heartbeat_at: run.last_heartbeat_at,
        finished_at: run.finished_at,
        created_at: run.created_at,
        updated_at: run.updated_at,
        agent_diff_present: agent_diff_bytes.positive?,
        agent_diff_bytes: agent_diff_bytes,
        step_agent_diff_present: step_agent_diff_bytes.positive?,
        step_agent_diff_bytes: step_agent_diff_bytes,
        job_log_count: metadata.fetch(:job_log_count, 0),
        agent_session: metadata[:agent_session],
        failure_classification: failure_classification(run.run_failure_classification, verbose: verbose),
        run_diagnostic: run.run_diagnostic && {
          error_class: run.run_diagnostic.error_class,
          error_message: run.run_diagnostic.error_message&.[](0, 1_000),
          error_message_truncated: run.run_diagnostic.error_message.to_s.length > 1_000,
          created_at: run.run_diagnostic.created_at
        }
      }
    rescue => e
      per_record_error(run, e)
    end

    def run_metadata_for(runs)
      run_ids = runs.map(&:id)
      return {} if run_ids.empty?

      metadata = Run.where(id: run_ids)
        .pluck(:id, Arel.sql(RunDiff.byte_length_sql(:agent_diff)), Arel.sql(RunDiff.byte_length_sql(:step_agent_diff)))
        .to_h { |id, diff_bytes, step_diff_bytes| [ id, { agent_diff_bytes: diff_bytes.to_i, step_agent_diff_bytes: step_diff_bytes.to_i } ] }

      JobLog.where(run_id: run_ids).group(:run_id).count.each do |run_id, count|
        metadata.fetch(run_id)[:job_log_count] = count
      end

      ProviderSession.where(run_id: run_ids)
        .pluck(
          :run_id, :session_id, :provider, :transcript_pruned,
          Arel.sql("LENGTH(transcript_jsonl)"),
          Arel.sql("CASE WHEN transcript_jsonl IS NULL THEN NULL ELSE LENGTH(transcript_jsonl) - LENGTH(REPLACE(transcript_jsonl, '\n', '')) END")
        ).each do |run_id, session_id, provider, transcript_pruned, transcript_bytes, transcript_lines|
          metadata.fetch(run_id)[:agent_session] = {
            session_id: session_id,
            provider: provider,
            transcript_pruned: transcript_pruned,
            transcript_bytes: transcript_bytes,
            transcript_lines: transcript_lines
          }
        end

      metadata
    end

    def projected_runs_for(steps)
      step_ids = steps.map(&:id)
      return {} if step_ids.empty?

      Run.where(step_id: step_ids)
        .select(*RUN_COLUMNS)
        .includes(:run_diagnostic, :run_failure_classification)
        .order(:created_at, :id)
        .group_by(&:step_id)
    end

    def workflow_failure_classification(runs, verbose: false)
      run = runs
              .select(&:failed?)
              .sort_by { |candidate| candidate.finished_at || candidate.updated_at || candidate.created_at }
              .last
      failure_classification(run&.run_failure_classification, verbose: verbose)
    end

    def failure_classification(classification, verbose: false)
      return unless classification

      payload = {
        id: classification.id,
        classification: classification.classification,
        confidence: classification.confidence&.to_f,
        retryable: classification.retryable,
        reason: classification.reason,
        diagnostic_summary: classification.diagnostic_summary,
        classified_at: classification.classified_at
      }
      payload[:classifier_inputs] = classification.classifier_inputs if verbose
      payload
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
