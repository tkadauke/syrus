module Adjudicators
  # Dismisses a required-grader failure whose every failing test already has
  # a confirmed-flaky history, stated as a rung-0 adjudicator
  # (workflow-engine-v3).
  #
  # InheritedGraderFailure catches "this was already broken on base." This
  # catches the case that motivated it: a spec that fails intermittently on
  # main too, so a single base-branch comparison cannot tell the failure
  # apart from a real regression -- exactly what stalled a merge train for
  # hours across dozens of retries. Flakiness history is not core's -- this
  # asks a `:test_evidence` provider the same way MainBranchFailureClassifier
  # does, and declines outright with no provider, no test-case evidence, or
  # no scoring history, rather than guessing.
  #
  # Opt-in per repository (Repository#known_flaky_failure_dismissal_enabled,
  # off by default): dismissing a real required-grader failure because its
  # test merely has a flaky reputation is a real risk, the same shape as
  # trust_clean_rebase_grade and land_on_inherited_check_failure.
  module KnownFlakyFailure
    # Below this flakiness score, a single historical blip should not be
    # enough to wave off a fresh failure. Repository#known_flaky_failure_min_score
    # overrides this per repository.
    DEFAULT_MIN_SCORE = 0.1

    def self.adjudicate(problem:, workflow: nil, step: nil, **)
      return Adjudication.inconclusive(adjudicator: name) unless problem&.code == "grader_failure"
      return Adjudication.inconclusive(adjudicator: name) unless workflow

      repository = workflow.job&.repository
      return Adjudication.inconclusive(adjudicator: name, reason: "not_enabled") unless repository&.known_flaky_failure_dismissal_enabled?

      steps = Array(step || TestEvidenceLookup.failed_grader_steps(workflow)).select { |candidate| candidate.respond_to?(:details) }
      return Adjudication.inconclusive(adjudicator: name) if steps.empty?

      min_score = repository.known_flaky_failure_min_score || DEFAULT_MIN_SCORE
      per_step_tests = steps.map { |grader_step| confirmed_tests_for(repository, grader_step, min_score) }
      return Adjudication.inconclusive(adjudicator: name, reason: "no_flakiness_history") if per_step_tests.any?(&:nil?)

      tests = per_step_tests.flatten(1)
      return Adjudication.inconclusive(adjudicator: name, reason: "not_all_confirmed_flaky") unless tests.all? { |entry| entry.fetch(:confirmed_flaky) }

      Adjudication.dismiss(
        adjudicator: name,
        reason: "known_flaky_failure",
        evidence: { tests: tests, min_score: min_score }
      )
    end

    # Returns, for one failed grader Step, an array of per-failing-test
    # flakiness verdicts -- or nil when there is not enough evidence to say
    # anything about this Step at all (no grader name, no Run, no failing
    # test cases recorded, or any one of them missing scoring history).
    def self.confirmed_tests_for(repository, grader_step, min_score)
      grader_name = grader_step.details.to_h["name"].to_s.presence
      return nil unless grader_name

      run = grader_step.runs.order(:created_at).last
      return nil unless run

      failing_tests = TestEvidenceLookup.failed_test_cases_for(run, grader_name)
      return nil if failing_tests.empty?

      failing_tests.map do |test_case|
        score = flakiness_score_for(repository, test_case)
        return nil if score.nil?

        {
          suite_name: test_case["suite_name"],
          name: test_case["name"],
          score: score[:score],
          confirmed_flaky: score[:flaky] && score[:score] >= min_score
        }
      end
    end

    def self.flakiness_score_for(repository, test_case)
      TestEvidenceLookup.test_evidence_providers.each do |provider|
        next unless provider.respond_to?(:flakiness_score)

        score = provider.flakiness_score(repository: repository, suite_name: test_case["suite_name"], name: test_case["name"])
        return score if score
      end
      nil
    end

    def self.name = "known_flaky_failure"
  end
end
