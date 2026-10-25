module Steps
  class SecurityReview < AdversarialReview
    private

    def review_step_kind = "security_review"
    def review_submit_tool = "submit_security_review"
    def review_event_kind = "security"
    def review_config = security_review_config
    def review_skip_label = "Security review"

    def reviewer_prompt
      Prompts::SecurityReview.new(
        issue: review_issue,
        diff: latest_agentic_diff,
        prior_findings: review_iterations.reject { |entry| entry["aggregate"] },
        base_ref: review_base_ref,
        workflow_kind: workflow.trigger_kind,
        feedback_context: feedback_context_text,
        criteria: security_review_criteria,
        affected_projects: security_review_projects.to_a
      ).to_s
    end

    def review_iterations
      Array(workflow.artifact("security_review_iterations"))
    end

    def security_review_config
      return @security_review_config if defined?(@security_review_config)
      @security_review_config = SyrusYml.load_repo(workspace.path).security_review
    rescue SyrusYml::ParseError, Errno::ENOENT
      @security_review_config = nil
    end

    def security_review_projects
      @security_review_projects ||= App::SecurityReviewProjects.call(
        workspace_path: workspace.path,
        changed_files: latest_agentic_changed_files
      )
    end

    def security_review_criteria
      [ *security_review_projects.criteria, *plugin_review_criteria ].uniq
    end
  end
end
