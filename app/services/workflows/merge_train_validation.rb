module Workflows
  # Feature-gated speculative prevalidation for the next same-repository Epic
  # merge-train landing unit. It builds the candidate integration tree on top
  # of the predicted base left by the current landing workflow and runs fast
  # landing graders. It never creates a MergeTrain row, pushes, repairs, or
  # merges; the real merge_train workflow remains the serialized publication
  # path and may reuse the recorded LandingValidationCache result.
  class MergeTrainValidation < Base
    def self.trigger_kind = "merge_train_validation"

    def self.agentic? = false

    def self.queue_name = :merges

    def self.steps_for(job)
      chain = [
        "speculative_merge_train_build",
        "prepare",
        *grader_gate_steps
      ]
      without_skipped_prepare(job, chain)
    end

    def self.after_success(workflow)
      LandingQueueProcessor.try_land!(workflow.job)
    end

    def self.after_fail(workflow)
      LandingQueueProcessor.try_land!(workflow.job)
    end

    def self.after_cancel(workflow)
      LandingQueueProcessor.try_land!(workflow.job)
    end
  end
end
