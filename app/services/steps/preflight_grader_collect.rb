module Steps
  # Aggregates the results of the preflight grader steps in a
  # MainBranchRepair workflow. Three outcomes:
  #
  # - At least one preflight grader ran and all required preflight graders
  #   passed: sets the "preflight_passed" workflow artifact, skips all
  #   downstream steps (implement, the grade loop, summarize, etc.), and
  #   returns. The dispatcher then walks past the skipped steps and marks the
  #   workflow succeeded.
  #   Workflows::MainBranchRepair#after_success detects the artifact and
  #   marks the repository healthy without the agent ever running.
  #   The downstream grade loop's own retry_until barrier (grader_collect)
  #   is one of the skipped steps; cancel_downstream! marks it
  #   retry_until_barrier_superseded so Workflow#uncleared_retry_until_barrier?
  #   doesn't hard-fail this otherwise-successful workflow.
  #
  # - Any required preflight grader did not succeed: logs the non-passing
  #   results and returns normally so the chain continues to implement →
  #   grade loop. This includes failed, cancelled, blocked, and skipped
  #   graders: none of those states proves main is healthy.
  #
  # - No preflight grader steps exist: logs the missing evidence and returns
  #   normally so the chain continues to implement → grade loop.
  #
  # Infrastructure resilience: every grader is classified with GraderOutcome.
  #
  # - A required grader that settled `infrastructure_failed` (worker death, lost
  #   result, database lock timeout, ...) is re-run on a fresh Step/Run, up to
  #   PreflightGraderPolicy.retry_budget times. The collector inserts the retry
  #   graders plus a replacement collector and finishes; only the retried
  #   grader is affected, never the whole Workflow. Genuine assertion failures
  #   (`test_failed`) are never retried as infrastructure.
  # - Only reproducible `test_failed` results are sent to the repair agent.
  # - If no required grader reproducibly failed but evidence is missing
  #   (exhausted infrastructure retries, inconclusive, cancelled), the
  #   `preflight_inconclusive` artifact is set and downstream steps are skipped:
  #   Workflows::MainBranchRepair#after_success keeps main health inconclusive
  #   and tells the operator, instead of spawning a coding repair.
  #
  # Unlike GraderCollect this step never raises StepFailed — it is not
  # inside a retry_until loop and a grader failure here means "proceed to
  # implement", not "fail the workflow".
  class PreflightGraderCollect < Base
    def call
      all_steps = preflight_grader_steps

      if all_steps.empty?
        log("[preflight_grader_collect] no preflight graders ran — proceeding to implement")
        return
      end

      # A retried grader supersedes the Step it retries; judge the latest one.
      preflight_steps = latest_steps_by_name(all_steps)

      nonpassing_required = preflight_steps.select do |grader_step|
        grader_step.details && grader_step.details["required"] && grader_step.state != "succeeded"
      end

      if nonpassing_required.empty?
        log("[preflight_grader_collect] all required graders passed (#{preflight_steps.size} grader step(s)) — skipping implement")
        workflow.set_artifact!("preflight_passed", true)
        cancel_downstream!(
          reason: "preflight graders passed — main is already healthy",
          supersede_retry_until_barriers: true
        )
        return
      end

      retryable = nonpassing_required.select { |grader_step| retryable_infrastructure_failure?(grader_step) }
      if retryable.any?
        schedule_infrastructure_retries!(retryable)
        return
      end

      reproducible, unproven = nonpassing_required.partition { |grader_step| outcome_for(grader_step).test_failed? }

      if reproducible.empty?
        record_inconclusive!(unproven)
        return
      end

      workflow.set_artifact!("preflight_failures", preflight_failure_entries(reproducible))
      workflow.set_artifact!("preflight_unproven", preflight_failure_entries(unproven)) if unproven.any?
      names = reproducible.map { |grader_step| "#{grader_step.details["name"]} (#{grader_step.state})" }.join(", ")
      log("[preflight_grader_collect] required preflight graders did not pass: #{names} — proceeding to implement")
      unless unproven.empty?
        log("[preflight_grader_collect] not sent to the repair agent (no reproducible failure): " \
            "#{unproven.map { |grader_step| "#{grader_step.details["name"]} (#{outcome_for(grader_step).outcome})" }.join(", ")}")
      end
    end

    private

    def preflight_grader_steps
      workflow.steps.where(kind: "preflight_grader").order(:position, :id).to_a
    end

    def latest_steps_by_name(steps)
      steps.group_by { |grader_step| grader_step.details.to_h["name"] }.values.map do |group|
        group.max_by { |grader_step| [ attempt_for(grader_step), grader_step.id ] }
      end.sort_by(&:position)
    end

    def attempt_for(grader_step)
      grader_step.details.to_h["infrastructure_retry_attempt"].to_i
    end

    def outcome_for(grader_step)
      @outcomes ||= {}
      @outcomes[grader_step.id] ||= begin
        details = grader_step.details.to_h
        if GraderOutcome::ALL.include?(details["outcome"]) && grader_step.state != "succeeded"
          GraderOutcome::Result.new(details["outcome"], details["outcome_reason"], {})
        else
          GraderOutcome.for_step(grader_step)
        end
      end
    end

    def retryable_infrastructure_failure?(grader_step)
      outcome_for(grader_step).outcome == GraderOutcome::INFRASTRUCTURE_FAILED &&
        attempt_for(grader_step) < PreflightGraderPolicy.retry_budget
    end

    # Inserts retry graders and a replacement collector after this step, then
    # lets this collector finish without deciding anything. The replacement
    # collector re-evaluates once the retries settle.
    def schedule_infrastructure_retries!(retryable)
      continuation = step.next_step
      replacement = nil
      retries = []

      Step.transaction do
        workflow.steps.where("position > ?", step.position).update_all([ "position = position + ?", retryable.size + 1 ])

        retries = retryable.each_with_index.map do |original, index|
          details = original.details.to_h.merge(
            "infrastructure_retry_attempt" => attempt_for(original) + 1,
            "retry_of_step_id" => original.id,
            "retry_reason" => outcome_for(original).reason,
            "previous_worker" => original.details.to_h["worker"] || original.details.to_h["worker_id"]
          ).compact
          %w[exit_code outcome outcome_reason output log_path log_bytes duration_s timed_out prepare_target_results coverage_output_results].each { |key| details.delete(key) }

          Step.create!(
            workflow: workflow, kind: "preflight_grader", position: step.position + 1 + index,
            iteration: original.iteration, placement_policy: original.placement_policy, details: details
          )
        end

        replacement = Step.create!(
          workflow: workflow, kind: "preflight_grader_collect", position: step.position + 1 + retries.size,
          iteration: step.iteration, placement_policy: step.placement_policy, details: step.details.to_h
        )
        replacement.update!(next_step_id: continuation&.id, depends_on_ids: retries.map(&:id))
        retries.each { |retry_step| retry_step.update!(depends_on_ids: [ step.id ], next_step_id: replacement.id) }
        step.update!(next_step_id: retries.first.id)
        rewire_continuation_dependencies!(continuation, replacement)
      end

      names = retries.map { |retry_step| "#{retry_step.details["name"]} (attempt #{retry_step.details["infrastructure_retry_attempt"]}/#{PreflightGraderPolicy.retry_budget})" }
      log("[preflight_grader_collect] infrastructure failure — re-running on a fresh execution context: #{names.join(", ")}")
    end

    def rewire_continuation_dependencies!(continuation, replacement)
      return unless continuation && continuation.depends_on_step_ids.include?(step.id)

      continuation.update!(depends_on_ids: continuation.depends_on_step_ids.map { |id| id == step.id ? replacement.id : id })
    end

    # No reproducible source failure, but required evidence is missing. Main
    # health stays inconclusive and an operator is told; no coding repair runs.
    def record_inconclusive!(unproven)
      workflow.set_artifact!("preflight_inconclusive", preflight_failure_entries(unproven))
      names = unproven.map { |grader_step| "#{grader_step.details["name"]} (#{outcome_for(grader_step).outcome}: #{outcome_for(grader_step).reason})" }.join(", ")
      log("[preflight_grader_collect] required preflight graders have no conclusive result: #{names} — " \
          "main health stays inconclusive, not spawning a coding repair")
      cancel_downstream!(
        reason: "preflight inconclusive — execution evidence missing, operator review required",
        supersede_retry_until_barriers: true
      )
    end

    # Named failing examples, from Test Insights evidence when a provider has
    # it for the grader's Run. Best effort: the exact command and log are
    # always recorded, so a missing provider only loses the names.
    def failed_test_names(grader_step, run, details)
      return details["failed_tests"] if details["failed_tests"].present?
      return nil unless run

      names = TestEvidenceLookup.failed_test_cases_for(run, details["name"]).filter_map do |test_case|
        test_case["identity"].presence || [ test_case["suite_name"], test_case["name"] ].compact.join(" ").presence
      end
      names.first(50).presence
    rescue StandardError
      nil
    end

    def preflight_failure_entries(grader_steps)
      grader_steps.map do |grader_step|
        details = grader_step.details.to_h
        outcome = outcome_for(grader_step)
        run = grader_step.runs.order(:id).last
        {
          "name" => details["name"],
          "command" => details["command"],
          "capabilities" => details["capabilities"],
          "required_capabilities" => details["required_capabilities"],
          "required" => details["required"],
          "status" => grader_step.state,
          "outcome" => outcome.outcome,
          "outcome_reason" => outcome.reason,
          "exit_code" => details["exit_code"],
          "duration_s" => details["duration_s"],
          "timed_out" => details["timed_out"],
          "log_path" => details["log_path"],
          "log_bytes" => details["log_bytes"],
          "junit_output" => details["junit_output"],
          "json_output" => details["json_output"],
          "failed_tests" => failed_test_names(grader_step, run, details),
          "source_sha" => details["source_sha"] || details.dig("source_snapshot", "source_sha"),
          "step_id" => grader_step.id,
          "run_id" => run&.id,
          "infrastructure_retry_attempt" => attempt_for(grader_step).positive? ? attempt_for(grader_step) : nil,
          "output" => details["output"]
        }.compact
      end
    end
  end
end
