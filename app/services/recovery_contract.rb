class RecoveryContract
  HISTORY_LIMIT = 20
  FAILURE_LIMIT = 20
  ROUND_LIMIT = 10
  TEXT_LIMIT = 500

  def self.for_job(job, workflow: nil) = new(job:, workflow:).job_payload
  def self.for_workflow(workflow) = new(job: workflow.job, workflow:).workflow_payload

  def initialize(job:, workflow: nil)
    @job = job
    @workflow = workflow || latest_recovery_workflow
  end

  def job_payload
    { decision: decision_payload, interventions: intervention_payload }
  end

  def workflow_payload
    { decision: decision_payload, repair_loops: repair_loop_payload }
  end

  private

  attr_reader :job, :workflow

  def latest_recovery_workflow
    id = job.workflows.where(state: %w[failed blocked cancelled])
      .reorder(created_at: :desc, id: :desc).pick(:id)
    Workflow.find_by(id:) if id
  end

  def decision = @decision ||= RecoveryDecision.for(job:, workflow:)

  def decision_payload
    return unless job.failed? || workflow&.state.in?(%w[failed blocked cancelled])

    rounds = bounded_rounds
    decision.as_json.except(:evidence).merge(
      explanation: snippet(decision.explanation),
      guidance: snippet(decision.guidance),
      evidence: bounded_evidence,
      measured_failures: bounded_text(Array(decision.evidence[:measured_failure_identities]), FAILURE_LIMIT),
      inconclusive_infrastructure_failures: infrastructure_failures(rounds),
      compared_repair_iterations: rounds.map { |round| round_summary(round) },
      stop_reason: snippet(stop_artifact["reason"]),
      references: canonical_references(decision.evidence)
    ).compact
  end

  def intervention_payload
    scope = job.recovery_interventions.reorder(performed_at: :desc, id: :desc)
    total = scope.count
    items = scope.limit(HISTORY_LIMIT).map do |item|
      {
        id: item.id, recovery_kind: item.recovery_kind, recovery_mode: item.recovery_mode,
        action: item.action, source_failure_classification: item.failure_classification,
        guidance: snippet(item.guidance), reason: snippet(item.reason),
        requested_actor: { type: item.actor_type, id: item.actor_id, display: item.actor_display }.compact,
        origin: item.origin, source_revision: item.source_revision, resulting_revision: item.resulting_revision,
        performed_at: item.performed_at&.iso8601,
        references: canonical_references(
          source_workflow_id: item.source_workflow_id, source_loop_id: item.source_loop_id,
          source_step_id: item.source_step_id, source_run_id: item.source_run_id,
          resulting_workflow_id: item.resulting_workflow_id, resulting_loop_id: item.resulting_loop_id,
          resulting_step_id: item.resulting_step_id, resulting_run_id: item.resulting_run_id
        )
      }.compact
    end
    { items:, total:, limit: HISTORY_LIMIT, truncated: total > HISTORY_LIMIT }
  end

  def repair_loop_payload
    return { items: [], total: 0, limit: ROUND_LIMIT, truncated: false, stop: {} } unless workflow

    rounds = Array(workflow&.artifact(GraderLoopProgress::ARTIFACT_KEY))
    total = rounds.size
    {
      items: rounds.last(ROUND_LIMIT).map { |round| round_summary(round) },
      total:, limit: ROUND_LIMIT, truncated: total > ROUND_LIMIT,
      stop: bounded_stop
    }
  end

  def bounded_rounds
    rounds = normalized_rounds(decision.evidence[:rounds]).presence || normalized_rounds(workflow&.artifact(GraderLoopProgress::ARTIFACT_KEY))
    rounds.last(ROUND_LIMIT)
  end

  def normalized_rounds(value)
    Array(value).select { |round| round.is_a?(Hash) }
  end

  def round_summary(round)
    repair = round.to_h["repair"].to_h
    {
      loop_id: snippet(round["loop_id"]), iteration: round["iteration"],
      source_revision: snippet(round["source_revision"]), repaired_revision: snippet(round["repaired_revision"]),
      transient_only: round["transient_only"] == true,
      measured_failures: bounded_text(Array(round["failing_set"]), FAILURE_LIMIT),
      repair: repair.slice("step_id", "run_id", "kind", "state", "agent_summary", "diff_bytes", "produced_diff")
        .transform_values { |value| value.is_a?(String) ? snippet(value) : value }
    }.compact
  end

  def infrastructure_failures(rounds)
    results = rounds.flat_map { |round| Array(round["grader_results"]) }
    run_ids = results.filter_map { |result| result["run_id"] }.uniq
    classifications = RunFailureClassification.where(run_id: run_ids).pluck(:run_id, :classification).to_h
    bounded(results.filter_map do |result|
      classification = classifications[result["run_id"]]
      next unless GraderLoopProgress::UNMEASURED_CLASSIFICATIONS.include?(classification.to_s)

      {
        name: snippet(result["name"]), step_id: result["step_id"], run_id: result["run_id"],
        classification:, timed_out: result["timed_out"], affected_decision: decision.kind == "infrastructure_only"
      }.compact
    end, FAILURE_LIMIT)
  end

  def stop_artifact = workflow&.artifact(GraderLoopProgress::STOP_ARTIFACT_KEY).to_h

  def bounded_evidence
    decision.evidence.except(:rounds, :measured_failure_identities).transform_values do |value|
      value.is_a?(String) ? snippet(value) : value
    end
  end

  def bounded_stop
    stop_artifact.slice("reason", "explanation", "previous_iteration", "current_iteration", "repeated_iteration", "stopped_at")
      .transform_values { |value| value.is_a?(String) ? snippet(value) : value }
  end

  def canonical_references(evidence)
    values = evidence.to_h.symbolize_keys
    {
      job: "JOB-#{job.id}", source_workflow: reference("WF", values[:source_workflow_id]),
      source_loop: values[:source_loop_id], source_step: reference("STEP", values[:source_step_id]),
      source_run: reference("RUN", values[:source_run_id]),
      resulting_workflow: reference("WF", values[:resulting_workflow_id]), resulting_loop: values[:resulting_loop_id],
      resulting_step: reference("STEP", values[:resulting_step_id]), resulting_run: reference("RUN", values[:resulting_run_id])
    }.compact
  end

  def reference(prefix, id)
    "#{prefix}-#{id}" if id
  end
  def snippet(value) = value.to_s.each_char.first(TEXT_LIMIT).join.presence
  def bounded(items, limit) = items.first(limit)
  def bounded_text(items, limit) = bounded(items, limit).filter_map { |item| snippet(item) }
end
