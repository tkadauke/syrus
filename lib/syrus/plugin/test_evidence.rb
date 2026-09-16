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
    #   .failed_test_cases(run:, grader_name:) => Array<Hash> ("suite_name", "name", "file_path", "identity")
    #   .flakiness_score(repository:, suite_name:, name:) => Hash (:score, :failed_count, :total_count, :flaky) or nil
    #
    # `flakiness_score` backs Adjudicators::KnownFlakyFailure: a rung-0 check
    # that dismisses a required-grader failure whose every failing test
    # already has a confirmed-flaky history, independent of whether the
    # failure also reproduces on the base branch. Return nil when there is no
    # scoring history for the given test -- that is "cannot tell," not "not
    # flaky."
    module TestEvidence
    end
  end
end
