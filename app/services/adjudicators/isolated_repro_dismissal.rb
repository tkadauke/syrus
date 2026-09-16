module Adjudicators
  # Dismisses a required-grader failure whose every failing test has an
  # agent-recorded, same-SHA, pre-fix "did not reproduce in isolation"
  # record, stated as a rung-0 adjudicator (workflow-engine-v3).
  #
  # A different, better-grounded signal than KnownFlakyFailure's
  # flakiness_score: that needs accumulated cross-run history and has
  # nothing to say about a test's very first failure. An isolated repro
  # attempt is a verifiable *action* -- a command and its raw output, not a
  # claim -- that can inform the decision for this one occurrence
  # immediately, without waiting on history to accumulate. It is also
  # distinct from a same-workflow retry_until re-run of the whole grader:
  # those are a normal grading execution and belong in TestCase's `scored`
  # statistical pool, not this path.
  #
  # This adjudicator trusts every record it finds because IsolatedReproRecorder
  # (the only writer, behind the record_isolated_repro MCP tool) already
  # rejected anything recorded against the wrong SHA or after the agent's own
  # fix commits exist -- see that class for the guardrail. This class only
  # has to check that a same-SHA "did not reproduce" record exists for every
  # currently failing test.
  #
  # Opt-in per repository (Repository#isolated_repro_dismissal_enabled, off
  # by default) -- same posture as KnownFlakyFailure: dismissing a real
  # required-grader failure is a real risk even with strong per-occurrence
  # evidence.
  module IsolatedReproDismissal
    def self.adjudicate(problem:, workflow: nil, step: nil, **)
      return Adjudication.inconclusive(adjudicator: name) unless problem&.code == "grader_failure"
      return Adjudication.inconclusive(adjudicator: name) unless workflow

      repository = workflow.job&.repository
      return Adjudication.inconclusive(adjudicator: name, reason: "not_enabled") unless repository&.isolated_repro_dismissal_enabled?

      sha = workflow.artifact(GraderConclusionCache::ARTIFACT_HEAD_SHA_KEY).presence
      return Adjudication.inconclusive(adjudicator: name, reason: "no_head_sha") unless sha

      steps = Array(step || TestEvidenceLookup.failed_grader_steps(workflow)).select { |candidate| candidate.respond_to?(:details) }
      return Adjudication.inconclusive(adjudicator: name) if steps.empty?

      per_step_tests = steps.map { |grader_step| confirmed_tests_for(repository, grader_step, sha) }
      return Adjudication.inconclusive(adjudicator: name, reason: "no_isolated_repro_evidence") if per_step_tests.any?(&:nil?)

      tests = per_step_tests.flatten(1)
      unless tests.all? { |entry| entry.fetch(:reproduced) == false }
        return Adjudication.inconclusive(adjudicator: name, reason: "not_all_confirmed_non_reproducing")
      end

      Adjudication.dismiss(
        adjudicator: name,
        reason: "isolated_repro_did_not_reproduce",
        evidence: { tests: tests, sha: sha }
      )
    end

    # Returns, for one failed grader Step, an array of per-failing-test
    # isolated-repro verdicts at the given SHA -- or nil when there is not
    # enough evidence to say anything about this Step at all (no grader
    # name, no Run, no failing test cases recorded, or any one of them
    # missing a same-SHA isolated repro record).
    def self.confirmed_tests_for(repository, grader_step, sha)
      grader_name = grader_step.details.to_h["name"].to_s.presence
      return nil unless grader_name

      run = grader_step.runs.order(:created_at).last
      return nil unless run

      failing_tests = TestEvidenceLookup.failed_test_cases_for(run, grader_name)
      return nil if failing_tests.empty?

      failing_tests.map do |test_case|
        evidence = isolated_repro_evidence_for(repository, test_case, sha)
        return nil if evidence.nil?

        {
          suite_name: test_case["suite_name"],
          name: test_case["name"],
          reproduced: evidence[:reproduced],
          recorded_at: evidence[:recorded_at]
        }
      end
    end

    def self.isolated_repro_evidence_for(repository, test_case, sha)
      TestEvidenceLookup.test_evidence_providers.each do |provider|
        next unless provider.respond_to?(:isolated_repro_evidence)

        evidence = provider.isolated_repro_evidence(repository: repository, suite_name: test_case["suite_name"], name: test_case["name"], sha: sha)
        return evidence if evidence
      end
      nil
    end

    def self.name = "isolated_repro_dismissal"
  end
end
