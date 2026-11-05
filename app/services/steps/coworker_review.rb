module Steps
  class CoworkerReview < AdversarialReview
    def call
      raise ProviderRouting::Resolver::CoworkerReviewTargetRequired, "coworker_review requires a pinned reviewer target" if step.details.to_h["reviewer_target"].blank?
      super
    end
    private
    def review_step_kind = "coworker_review"
    def review_submit_tool = "submit_coworker_review"
    def review_event_kind = "coworker"
    def review_config = nil
    def review_skip_label = "Coworker review"
    def review_iterations = Array(workflow.artifact("coworker_review_iterations"))
    def skippable_review_failure?(_exception) = false
    def reviewer_prompt
      Prompts::CoworkerReview.new(issue: review_issue, diff: latest_agentic_diff, prior_findings: review_iterations,
        base_ref: review_base_ref, workflow_kind: workflow.trigger_kind, feedback_context: feedback_context_text,
        criteria: review_criteria, affected_projects: adversarial_review_projects.to_a).to_s
    end
  end
end
