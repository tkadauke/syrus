require "digest"

class GraderLoopProgress
  ARTIFACT_KEY = "grader_loop_progress".freeze
  STOP_ARTIFACT_KEY = "grader_loop_stop".freeze
  NO_PROGRESS_REASON = "grader_loop_no_progress".freeze

  def self.record_failure!(workflow:, collect_step:)
    new(workflow: workflow, collect_step: collect_step).record_failure!
  end

  def self.no_progress_repair_for_sha?(job, sha)
    return false if sha.blank? || sha == "unknown"

    job.needs_attention_reason == NO_PROGRESS_REASON &&
      job.issue_body.to_s.include?("Commit: #{sha}")
  end

  def initialize(workflow:, collect_step:)
    @workflow = workflow
    @collect_step = collect_step
  end

  def record_failure!
    return Result.continue unless retry_until_grader_collect?

    current = round_payload
    prior = previous_round
    rounds = Array(workflow.artifact(ARTIFACT_KEY)).reject { |round| round["iteration"] == current["iteration"] }
    workflow.set_artifact!(ARTIFACT_KEY, rounds + [ current ])

    return Result.continue unless prior
    return Result.continue if progressing?(prior.fetch("failing_set"), current.fetch("failing_set"))

    stop = stop_payload(prior, current)
    workflow.set_artifact!(STOP_ARTIFACT_KEY, stop)
    workflow.job.set_needs_attention!(reason: NO_PROGRESS_REASON)
    Result.stop(stop)
  end

  Result = Data.define(:stop?, :payload) do
    def self.continue = new(false, nil)
    def self.stop(payload) = new(true, payload)
  end

  private

  attr_reader :workflow, :collect_step

  def retry_until_grader_collect?
    collect_step.kind == "grader_collect" && collect_step.loop_id.present?
  end

  def previous_round
    Array(workflow.artifact(ARTIFACT_KEY))
      .select { |round| round["loop_id"] == collect_step.loop_id && round["iteration"].to_i < collect_step.iteration }
      .max_by { |round| round["iteration"].to_i }
  end

  def progressing?(prior_set, current_set)
    prior = Array(prior_set)
    current = Array(current_set)
    current.present? && (current - prior).empty? && current.length < prior.length
  end

  def round_payload
    failed_graders = failed_required_graders
    failing_set = failed_graders.flat_map { |grader| failing_identities_for(grader) }.uniq.sort
    result = failed_graders.map { |grader| grader_result_payload(grader) }
    repair = repair_step_payload

    {
      "loop_id" => collect_step.loop_id,
      "iteration" => collect_step.iteration,
      "collect_step_id" => collect_step.id,
      "collect_run_id" => collect_step.latest_run&.id,
      "grader_results" => result,
      "failing_set" => failing_set,
      "failing_set_digest" => Digest::SHA256.hexdigest(failing_set.join("\0")),
      "repair" => repair,
      "recorded_at" => Time.current.iso8601
    }
  end

  def stop_payload(prior, current)
    {
      "reason" => NO_PROGRESS_REASON,
      "stopped_at" => Time.current.iso8601,
      "job_id" => workflow.job_id,
      "job_slug" => workflow.job.slug,
      "workflow_id" => workflow.id,
      "workflow_slug" => workflow.slug,
      "trigger_kind" => workflow.trigger_kind,
      "loop_id" => collect_step.loop_id,
      "previous_iteration" => prior["iteration"],
      "current_iteration" => current["iteration"],
      "explanation" => stop_explanation(prior.fetch("failing_set"), current.fetch("failing_set")),
      "failing_set" => current.fetch("failing_set"),
      "rounds" => [ prior, current ]
    }
  end

  def stop_explanation(prior_set, current_set)
    prior = Array(prior_set)
    current = Array(current_set)
    return "failing set unchanged" if prior == current

    introduced = current - prior
    fixed = prior - current
    "failing set did not shrink monotonically; fixed #{fixed.length}, introduced #{introduced.length}"
  end

  def failed_required_graders
    workflow.steps
      .where(kind: "grader", loop_id: collect_step.loop_id, iteration: collect_step.iteration, state: "failed")
      .order(:position)
      .select { |grader| grader.details.to_h["required"] }
  end

  def grader_result_payload(grader)
    details = grader.details.to_h
    latest_run = grader.latest_run
    {
      "step_id" => grader.id,
      "run_id" => latest_run&.id,
      "name" => details["name"],
      "command" => details["command"],
      "exit_code" => details["exit_code"],
      "duration_s" => details["duration_s"],
      "timed_out" => details["timed_out"],
      "log_path" => details["log_path"],
      "log_bytes" => details["log_bytes"],
      "output" => details["output"],
      "failed_tests" => failed_tests_for(grader)
    }.compact
  end

  def failing_identities_for(grader)
    tests = failed_tests_for(grader)
    return tests.map { |test| test_identity(test) }.compact.presence if tests.present?

    details = grader.details.to_h
    name = details["name"].to_s.presence || "grader:#{grader.id}"
    output = details["output"].to_s.squish
    command = details["command"].to_s.squish
    [ [ name, command, output ].join("\0") ]
  end

  def failed_tests_for(grader)
    run = grader.latest_run
    return [] unless run

    TestEvidenceLookup.failed_test_cases_for(run, grader.details.to_h["name"])
  end

  def test_identity(test)
    test["identity"].presence ||
      [ test["suite_name"], test["name"], test["file_path"] ].compact.join(" - ").presence
  end

  def repair_step_payload
    repair_step = workflow.steps
      .where(loop_id: collect_step.loop_id, iteration: collect_step.iteration, kind: Step::AGENTIC_KINDS)
      .where("position < ?", collect_step.position)
      .order(position: :desc)
      .first
    return unless repair_step

    run = repair_step.latest_run
    diff = run&.step_agent_diff || run&.agent_diff
    {
      "step_id" => repair_step.id,
      "run_id" => run&.id,
      "kind" => repair_step.kind,
      "state" => repair_step.state,
      "agent_summary" => run&.agent_summary,
      "diff_bytes" => diff.to_s.bytesize,
      "produced_diff" => diff.present?
    }.compact
  end
end
