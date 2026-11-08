module Coworkers
  class ReviewStep < Steps::AdversarialReview
    MemoryPersistenceFailed = Steps::AdversarialReview::MemoryPersistenceFailed
    def call
      raise ReviewerTargets::TargetRequired, "coworker_review requires a pinned reviewer target" if step.details.to_h["reviewer_target"].blank?
      super
    end
    private
    def review_step_kind = "coworker_review"
    def review_submit_tool = "submit_coworker_review"
    def review_event_kind = "coworker"
    def review_config = coworker_review_config
    def review_skip_label = "Coworker review"
    def review_iterations = Array(workflow.artifact("coworker_review_iterations"))
    def reviewer_prompt
      Coworkers::ReviewPrompt.new(issue: review_issue, diff: latest_agentic_diff, prior_findings: review_iterations,
        base_ref: review_base_ref, workflow_kind: workflow.trigger_kind, feedback_context: feedback_context_text,
        criteria: review_criteria, affected_projects: coworker_review_projects.to_a).to_s
    end

    def review_criteria = coworker_review_projects.criteria
    def coworker_review_projects
      @coworker_review_projects ||= Coworkers::ReviewProjects.call(
        workspace_path: workspace.path,
        changed_files: latest_agentic_changed_files
      )
    end
    def coworker_review_config
      SyrusYml.load_repo(workspace.path).plugin_configurations[Coworkers::ReviewPlan::KEY]
    rescue SyrusYml::ParseError, Errno::ENOENT
      nil
    end
  end
end
