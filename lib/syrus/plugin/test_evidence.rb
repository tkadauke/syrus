module Syrus
  module Plugin
    # Marker interface for a plugin that can answer "which tests failed in this
    # run?".
    #
    # Core's main-branch failure classifier uses that to tell a grader failure
    # inherited from a broken base branch from one the PR introduced. It is a
    # read of data core does not own, so it asks rather than reaching for a
    # model: with no provider the classifier falls back to its coarser
    # pass/fail comparison, which is the behavior repositories without test
    # data already got.
    #
    #   .test_case_count(run:, grader_name:)        => Integer
    #   .failed_test_identities(run:, grader_name:) => Array<String>
    #
    # Two further capabilities are optional (checked with `respond_to?` by
    # callers, so a provider that predates them still works):
    #
    #   .failed_test_cases(run:, grader_name:) => Array<Hash> ("suite_name", "name", "file_path", "identity",
    #                                                          "failure_message" [optional, short/bounded])
    #   .flakiness_score(repository:, suite_name:, name:) => Hash (:score, :failed_count, :total_count, :flaky) or nil
    #
    # `flakiness_score` backs Adjudicators::KnownFlakyFailure: a rung-0 check
    # that dismisses a required-grader failure whose every failing test
    # already has a confirmed-flaky history, independent of whether the
    # failure also reproduces on the base branch. Return nil when there is no
    # scoring history for the given test -- that is "cannot tell," not "not
    # flaky."
    #
    # Two more capabilities back Adjudicators::IsolatedReproDismissal -- a
    # different, per-occurrence signal from flakiness_score's accumulated
    # cross-run history, so it is stored separately and must never feed
    # flakiness_score's statistical pool:
    #
    #   .record_isolated_repro!(repository:, grader_name:, suite_name:, name:, sha:,
    #                            reproduced:, command:, output:, exit_status: nil,
    #                            job: nil, workflow: nil, run: nil) => void
    #   .isolated_repro_evidence(repository:, suite_name:, name:, sha:)
    #     => Hash (:reproduced, :recorded_at, :command, :grader_name) or nil
    #
    # `record_isolated_repro!` is a plain writer -- IsolatedReproRecorder
    # (core) validates the SHA and the failing-test match before calling it,
    # so a provider does not need to re-derive that itself. Return nil from
    # `isolated_repro_evidence` when no record exists for the given
    # (suite_name, name, sha) -- "cannot tell," not "reproduced."
    module TestEvidence
    end
  end
end
