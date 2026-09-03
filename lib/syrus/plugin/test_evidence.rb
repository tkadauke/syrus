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
    module TestEvidence
    end
  end
end
