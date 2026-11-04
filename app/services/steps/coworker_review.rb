module Steps
  class CoworkerReview < AdversarialReview
    private

    def review_step_kind = "coworker_review"
    def review_event_kind = "coworker"
    def review_config = nil
    def review_skip_label = "Coworker review"

    def review_iterations
      Array(workflow.artifact("coworker_review_iterations"))
    end
  end
end
