module Workflows
  class ManualPostImplementationReview < Base
    def self.trigger_kind = "manual_post_implementation_review"

    def self.steps_for(job)
      prepare_then(job, "post_implementation_review")
    end
  end
end
