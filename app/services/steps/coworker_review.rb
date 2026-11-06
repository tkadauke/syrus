module Steps
  class CoworkerReview < AdversarialReview
    class MemoryPersistenceFailed < StepFailed
      problem_code :coworker_memory_persistence_failed
    end
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
    def materialize_reviewer_prompt
      prompt = reviewer_prompt
      reviewer = run.review_evidence&.reviewer
      return prompt unless reviewer&.respond_to?(:prepare_review_context!)

      context = reviewer.prepare_review_context!(run:, evidence: run.review_evidence, criteria: review_criteria)
      "#{prompt}\n\n#{reviewer.review_context_prompt(context)}"
    end
    def verify_reviewer_side_effects!
      reviewer = run.review_evidence&.reviewer
      return unless reviewer&.respond_to?(:finalize_review_memory!)
      context = reviewer.review_context_for(run)
      return if context&.persistence_state == "persisted"

      raise MemoryPersistenceFailed.new("coworker review memory was not persisted",
        evidence: { review_evidence_id: run.review_evidence.id, persistence_state: context&.persistence_state || "missing",
                    persistence_error: context&.persistence_error_details })
    end
    def reviewer_prompt
      Prompts::CoworkerReview.new(issue: review_issue, diff: latest_agentic_diff, prior_findings: review_iterations,
        base_ref: review_base_ref, workflow_kind: workflow.trigger_kind, feedback_context: feedback_context_text,
        criteria: review_criteria, affected_projects: adversarial_review_projects.to_a).to_s
    end
  end
end
