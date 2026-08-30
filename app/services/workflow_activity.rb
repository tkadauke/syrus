class WorkflowActivity
  class << self
  def synchronously
    previous = Thread.current[:syrus_workflow_activity_synchronous]
    Thread.current[:syrus_workflow_activity_synchronous] = true
    yield
  ensure
    Thread.current[:syrus_workflow_activity_synchronous] = previous
  end

  def record!(event_type:, source:, message:, severity: "info", job: nil, workflow: nil, step: nil, run: nil, repository: nil, epic: nil, reason_key: nil, duration_ms: nil, metadata: {}, occurred_at: Time.current)
    workflow ||= step&.workflow || run&.workflow
    job ||= workflow&.job || run&.job || step&.workflow&.job
    repository ||= job&.repository
    epic ||= job&.epic
    step ||= run&.step

    event = {
      "event" => "syrus.workflow_activity",
      "occurred_at" => occurred_at.iso8601(6),
      "event_type" => event_type.to_s,
      "source" => source.to_s,
      "severity" => severity.to_s,
      "app_revision" => SyrusVersion.current,
      "hostname" => SyrusVersion.hostname,
      "pid" => Process.pid,
      "queue_role" => Thread.current[:syrus_current_queue_role],
      "repository_id" => repository&.id,
      "epic_id" => epic&.id,
      "job_id" => job&.id,
      "workflow_id" => workflow&.id,
      "step_id" => step&.id,
      "run_id" => run&.id,
      "trigger_kind" => workflow&.trigger_kind || run&.trigger_kind,
      "workflow_state" => workflow&.state,
      "step_kind" => step&.kind,
      "run_state" => run&.state,
      "reason_key" => reason_key&.to_s,
      "duration_ms" => duration_ms,
      "message" => message.to_s,
      "metadata" => safe_metadata(metadata)
    }.compact

    if synchronous?
      Observability::EventStream.fetch(:workflow_activity).persist!([ event ], batch_size: 1)
    else
      Observability::EventSink.append(kind: :workflow_activity, event: event, durable: true)
    end
    event
  rescue StandardError => e
    Rails.logger.warn("[WorkflowActivity] record failed: #{e.class}: #{e.message}")
    nil
  end

  def workflow_created!(workflow)
    record!(
      event_type: "workflow_created",
      source: "workflow",
      workflow: workflow,
      message: "#{workflow.job.slug} created #{workflow.slug} (#{workflow.trigger_kind}).",
      metadata: workflow_metadata(workflow)
    )
  end

  def workflow_state_changed!(workflow)
    return unless workflow.saved_change_to_state?

    from_state, to_state = workflow.saved_change_to_state
    event_type = workflow.terminal? ? "workflow_finished" : "workflow_started"
    reason_key = StateTransition.reason_key_for(workflow)
    record!(
      event_type: event_type,
      source: "workflow",
      workflow: workflow,
      severity: workflow.failed? ? "error" : "info",
      reason_key: reason_key,
      duration_ms: duration_between(workflow.started_at, workflow.finished_at),
      message: "#{workflow.slug} #{from_state} -> #{to_state}.",
      metadata: workflow_metadata(workflow)
        .merge(from_state: from_state, to_state: to_state)
        .merge(StateTransition.transition_metadata_for(workflow))
    )
  end

  def run_state_changed!(run)
    return unless run.saved_change_to_state?

    from_state, to_state = run.saved_change_to_state
    terminal = run.terminal?
    reason_key = StateTransition.reason_key_for(run)
    record!(
      event_type: terminal ? "run_finished" : "run_started",
      source: "run",
      run: run,
      severity: run.failed? ? "error" : "info",
      reason_key: reason_key,
      duration_ms: duration_between(run.started_at, run.finished_at),
      message: "Run ##{run.id} #{from_state} -> #{to_state}.",
      metadata: {
        from_state: from_state,
        to_state: to_state
      }.merge(StateTransition.transition_metadata_for(run)).compact
    )
  end

  def landing_queue_changed!(job, before:, after:)
    reason = after[:blocked_reason].to_h
    reason_key = reason["key"] || reason[:key]
    record!(
      event_type: "landing_queue_changed",
      source: "landing_queue",
      job: job,
      severity: reason_key.present? ? "warn" : "info",
      reason_key: reason_key,
      message: "#{job.slug} landing queue snapshot changed.",
      metadata: {
        before: before,
        after: after
      }
    )
  end

  def landing_workflow_dispatched!(job, workflow)
    record!(
      event_type: "landing_workflow_dispatched",
      source: "landing_queue",
      job: job,
      workflow: workflow,
      message: "#{job.slug} dispatched #{workflow.slug} (#{workflow.trigger_kind}) from landing queue.",
      metadata: workflow_metadata(workflow)
    )
  end

  def duration_between(started_at, finished_at)
    return unless started_at && finished_at

    ((finished_at - started_at) * 1000.0).round(1)
  end

  def workflow_metadata(workflow)
    {
      trigger_kind: workflow.trigger_kind,
      agent_provider: workflow.agent_provider,
      state: workflow.state,
      created_at: workflow.created_at&.iso8601,
      started_at: workflow.started_at&.iso8601,
      finished_at: workflow.finished_at&.iso8601
    }.compact
  end

  def safe_metadata(metadata)
    JSON.parse(JSON.generate(metadata || {}))
  rescue JSON::ParserError, TypeError
    {}
  end

  def synchronous?
    Thread.current[:syrus_workflow_activity_synchronous]
  end
  end
end
