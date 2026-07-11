module Workflows
  # Land a whole Epic's children together as one atomic merge.
  #
  #   merge_train_assemble → merge_train_build → prepare →
  #     retry_until(grader_fanout → grader_collect, repair: landing_fix) →
  #     try(merge_train_land).on_failure("merge_train_base_moved",
  #       merge_train_rebase →
  #       retry_until(grader_fanout → grader_collect, repair: landing_fix) →
  #       merge_train_land_after_rebase)
  #
  # assemble validates the train members; build rebases/merges them into a
  # single integration branch in topological order; prepare installs deps;
  # the grade & fix loop runs graders ONCE on the integrated tip (the exact
  # tree that will exist on base after the Epic merges) and lets the agent
  # commit reconciliation fixes; land merges the integration branch into the
  # base in a single atomic merge and closes the child PRs. There is no
  # bisection — an unrepairable integration fails the whole Epic attempt and
  # lands nothing (Epic consistency). See docs/plans/landing-merge-train.md.
  #
  # When merge_train_land detects that the base branch moved (before or during
  # the merge API call), it raises BaseMoved with failure_code
  # "merge_train_base_moved". The Try node inserts merge_train_rebase (tries a
  # mechanical git-rebase of the integration branch onto the new base tip), a
  # fresh grader loop, and merge_train_land_after_rebase. If the incremental
  # rebase conflicts, merge_train_rebase fails with "rebuild required" and
  # MergeTrainFailureHandler falls back to a full merge_train rebuild.
  class MergeTrain < Base
    steps :merge_train_assemble,
          :merge_train_build,
          :prepare,
          Workflows::RetryUntil.new(
            repair_first: false,
            repair: [ :landing_fix ],
            check: [ :grader_fanout, :grader_collect ]
          ),
          Workflows::Try.new(:merge_train_land).on_failure(
            Steps::MergeTrainLand::BaseMoved::FAILURE_CODE,
            [
              :merge_train_rebase,
              Workflows::RetryUntil.new(
                repair_first: false,
                repair: [ :landing_fix ],
                check: [ :grader_fanout, :grader_collect ]
              ),
              :merge_train_land_after_rebase
            ]
          )

    def self.trigger_kind = "merge_train"

    def self.queue_name = :merges

    def self.steps_for(_job)
      [
        "merge_train_assemble",
        "merge_train_build",
        "prepare",
        Workflows::RetryUntil.new(
          max_iterations: AppSetting.grade_max_iterations,
          repair_first: false,
          repair: [ :landing_fix ],
          check: [ :grader_fanout, :grader_collect ]
        ),
        Workflows::Try.new(:merge_train_land).on_failure(
          Steps::MergeTrainLand::BaseMoved::FAILURE_CODE,
          [
            :merge_train_rebase,
            Workflows::RetryUntil.new(
              max_iterations: AppSetting.grade_max_iterations,
              repair_first: false,
              repair: [ :landing_fix ],
              check: [ :grader_fanout, :grader_collect ]
            ),
            :merge_train_land_after_rebase
          ]
        )
      ]
    end

    def self.after_fail(workflow)
      MergeTrainFailureHandler.call(workflow: workflow)
    end

    def self.after_cancel(workflow)
      MergeTrainFailureHandler.call(workflow: workflow, cancelled: true)
    end
  end
end
