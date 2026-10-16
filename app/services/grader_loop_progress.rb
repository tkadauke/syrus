require "digest"

class GraderLoopProgress
  ARTIFACT_KEY = "grader_loop_progress".freeze
  STOP_ARTIFACT_KEY = "grader_loop_stop".freeze
  NO_PROGRESS_REASON = "grader_loop_no_progress".freeze

  # A grader that was killed, or that never got far enough to judge the tree,
  # reached no verdict -- so it says nothing about whether the repair is
  # progressing, and counting it as a failure turns absence of evidence into
  # evidence of regression. A timeout belongs here for the same reason the
  # infrastructure classifications do: the command was killed, so its result
  # is "unknown", not "failing". Three merge trains in one production week
  # were stopped as stalled by a round in which graders had merely timed out
  # under host pressure -- one of them after 214 minutes of landing work, all
  # of which was discarded.
  UNMEASURED_CLASSIFICATIONS =
    (Steps::GraderCollect::INFRASTRUCTURE_FAILURE_CLASSIFICATIONS + %w[ timeout ]).freeze

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
    earlier = earlier_rounds(current)
    prior = earlier.max_by { |round| round["iteration"].to_i }
    rounds = Array(workflow.artifact(ARTIFACT_KEY)).reject { |round| round["iteration"] == current["iteration"] }
    workflow.set_artifact!(ARTIFACT_KEY, rounds + [ current ])

    return Result.continue if current["transient_only"]
    return Result.continue unless prior

    repeated = repeated_round(earlier, current)
    if repeated.nil? && progressing?(prior.fetch("failing_set"), current.fetch("failing_set"))
      workflow.job.clear_needs_attention!(reason: NO_PROGRESS_REASON)
      return Result.continue
    end

    stop = stop_payload(prior, current, repeated)
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

  # A round whose required graders all failed for infrastructure reasons is
  # not a measurement of the repair's progress: `Steps::GraderCollect` marks
  # it transient, `StepDispatcher` skips the repair for it entirely, and the
  # loop simply regrades. Its failing set reflects whichever workers died,
  # not the state of the tree, so comparing a real round against it answers
  # the wrong question -- a rolling deploy that killed graders mid-fan-out
  # produced a transient round, and the next genuine round was then judged
  # against that noise and stopped.
  def earlier_rounds(current)
    comparable_rounds.select do |round|
      round["loop_id"] == collect_step.loop_id && round["iteration"].to_i < current["iteration"].to_i
    end
  end

  # The loop has been in this exact state before, so whatever the repair is
  # doing, it is cycling rather than converging. This is the condition the
  # old shrink-or-stop rule was really reaching for, and unlike that rule it
  # does not depend on which round happens to be adjacent: a loop that
  # alternates between two failing sets is caught here, while one that keeps
  # genuinely fixing things is not.
  def repeated_round(earlier, current)
    return nil if Array(current["failing_set"]).empty?

    earlier.find { |round| round["failing_set_digest"] == current["failing_set_digest"] }
  end

  def comparable_rounds
    Array(workflow.artifact(ARTIFACT_KEY)).reject { |round| round["transient_only"] }
  end

  # Progress is "something that was failing is now passing". Requiring the
  # set to shrink instead measured the wrong thing, because the set spans
  # every required grader at once: a repair that fixed the grader it was
  # given and then saw one unrelated spec fail -- a flaky seeded-random
  # spec, say, or an entirely different grader -- scored "fixed 1,
  # introduced 1" and the loop was stopped as stalled. Three merge trains in
  # one production week died that way, each discarding a landing attempt
  # that was converging.
  #
  # The cases a stop is actually for are still caught: a round that fixes
  # nothing stops here, whether the failing set stood still or only grew,
  # and a loop that cycles back to a set it has already produced stops in
  # repeated_round. Beyond that the iteration budget
  # (AppSetting.grade_max_iterations) is the bound, which is what it is for.
  def progressing?(prior_set, current_set)
    (Array(prior_set) - Array(current_set)).any?
  end

  def round_payload
    failed_graders = failed_required_graders
    measured_graders = failed_graders.reject { |grader| unmeasured?(grader) }
    failing_set = measured_graders.flat_map { |grader| failing_identities_for(grader) }.uniq.sort
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
      "transient_only" => transient_only_round? || (failed_graders.any? && measured_graders.empty?),
      "recorded_at" => Time.current.iso8601
    }
  end

  def transient_only_round?
    collect_step.details.to_h[Steps::GraderCollect::TRANSIENT_ONLY_FAILURE_DETAIL_KEY] == true
  end

  # GraderCollect marks the whole round transient only when *every* failing
  # required grader was infrastructure, because that is the question it is
  # answering: whether to materialize a repair agent at all. A round with one
  # real failure and one killed grader still needs a repair, so it is not
  # transient -- but the killed grader must still stay out of the comparison.
  def unmeasured?(grader)
    classification = grader.latest_run&.run_failure_classification&.classification
    UNMEASURED_CLASSIFICATIONS.include?(classification.to_s)
  end

  def stop_payload(prior, current, repeated = nil)
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
      "repeated_iteration" => repeated && repeated["iteration"],
      "explanation" => stop_explanation(prior, current, repeated),
      "failing_set" => current.fetch("failing_set"),
      "rounds" => [ prior, current ]
    }
  end

  def stop_explanation(prior, current, repeated)
    prior_set = Array(prior.fetch("failing_set"))
    current_set = Array(current.fetch("failing_set"))
    if repeated
      return "failing set unchanged" if repeated["iteration"] == prior["iteration"]

      return "failing set repeats iteration #{repeated['iteration']}; the loop is cycling"
    end

    introduced = current_set - prior_set
    "nothing that was failing is passing now; #{introduced.length} new failure(s)"
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
