class LandingRepairOutcome
  ARTIFACT_KEY = "landing_repair_outcomes".freeze
  SUMMARY_ARTIFACT_KEY = "landing_repair_summary".freeze
  NO_PROGRESS_LIMIT = 2
  FLAKY_RETRY_LIMIT = 1

  OUTCOMES = %w[
    committed_repair
    verified_no_change_resolution
    explicit_flaky_retry
    inconclusive_no_op
  ].freeze

  def self.record!(step:, outcome:, evidence: {})
    raise ArgumentError, "unknown landing repair outcome: #{outcome}" unless OUTCOMES.include?(outcome.to_s)

    workflow = step.workflow
    entry = {
      "outcome" => outcome.to_s,
      "loop_id" => step.loop_id,
      "iteration" => step.iteration,
      "step_id" => step.id,
      "run_id" => step.runs.order(:created_at).last&.id,
      "evidence" => evidence.to_h.compact,
      "recorded_at" => Time.current.iso8601
    }
    entries = Array(workflow.artifact(ARTIFACT_KEY)).reject { |item| item["step_id"] == step.id }
    workflow.set_artifact!(ARTIFACT_KEY, entries + [ entry ])
    step.update!(details: step.details.to_h.merge("landing_repair_outcome" => entry))
    entry
  end

  def self.record_flaky_retry!(collect_step)
    record!(
      step: collect_step,
      outcome: "explicit_flaky_retry",
      evidence: {
        "reason" => "transient_or_infrastructure_failure",
        "failing_context" => collect_step.details.to_h.slice(
          Steps::GraderCollect::TRANSIENT_ONLY_FAILURE_DETAIL_KEY,
          "failure_code"
        )
      }
    )
  end

  def self.counters(workflow:, loop_id:)
    scoped = Array(workflow.artifact(ARTIFACT_KEY)).select { |entry| entry["loop_id"] == loop_id }
    counts = scoped.each_with_object(Hash.new(0)) { |entry, result| result[entry.fetch("outcome")] += 1 }
    {
      "repair_iterations" => counts["committed_repair"],
      "no_progress_attempts" => counts["inconclusive_no_op"],
      "flaky_retries" => counts["explicit_flaky_retry"],
      "verified_resolutions" => counts["verified_no_change_resolution"],
      "outcomes" => scoped
    }
  end

  def self.record_summary!(workflow:, loop_id:, repair_limit:, reason: nil)
    summary = counters(workflow: workflow, loop_id: loop_id).merge(
      "repair_limit" => repair_limit,
      "no_progress_limit" => NO_PROGRESS_LIMIT,
      "flaky_retry_limit" => FLAKY_RETRY_LIMIT,
      "reason" => reason,
      "recorded_at" => Time.current.iso8601
    ).compact
    workflow.set_artifact!(SUMMARY_ARTIFACT_KEY, summary)
    summary
  end

  def self.verify_latest_no_change!(collect_step)
    workflow = collect_step.workflow
    entries = Array(workflow.artifact(ARTIFACT_KEY))
    index = entries.rindex do |entry|
      entry["loop_id"] == collect_step.loop_id && entry["outcome"] == "inconclusive_no_op"
    end
    return unless index

    grader_steps = workflow.steps.where(
      loop_id: collect_step.loop_id,
      iteration: collect_step.iteration,
      kind: "grader"
    ).order(:position)
    entries[index] = entries[index].merge(
      "outcome" => "verified_no_change_resolution",
      "evidence" => entries[index].fetch("evidence", {}).merge(
        "successful_equivalent_rerun" => grader_steps.map do |grader|
          {
            "grader" => grader.details.to_h["name"],
            "command" => grader.details.to_h["command"],
            "step_id" => grader.id,
            "run_id" => grader.runs.order(:created_at).last&.id,
            "state" => grader.state
          }.compact
        end,
        "collect_step_id" => collect_step.id
      ),
      "verified_at" => Time.current.iso8601
    )
    workflow.set_artifact!(ARTIFACT_KEY, entries)
  end
end
