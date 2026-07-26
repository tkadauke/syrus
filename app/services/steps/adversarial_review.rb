module Steps
  class AdversarialReview < Base
    def call
      workspace.setup
      run.update!(prompt: reviewer_prompt) if run.prompt.blank?

      before_count = review_iterations.size
      log("invoking agent for adversarial_review step (#{workflow.slug}, step ##{step.id}, iteration #{step.iteration})")

      run_agent(prompt: run.prompt, required_mcp_tools: %w[submit_adversarial_review])
      discard_reviewer_workspace_changes

      workflow.reload
      if review_iterations.size <= before_count
        capture_mcp_sidecar_stderr
        raise StepFailed, "agent didn't call submit_adversarial_review"
      end
    end

    private

    def parent_session_id
      run.parent_session_id.presence ||
        workflow.steps
          .where(kind: "adversarial_review", loop_id: step.loop_id)
          .where("iteration < ?", step.iteration)
          .order(iteration: :desc)
          .first&.latest_run&.claude_session&.session_id
    end

    FEEDBACK_TRIGGER_KINDS = %w[pr_comment chat_feedback].freeze

    def reviewer_prompt
      Prompts::AdversarialReview.new(
        issue: review_issue,
        diff: latest_agentic_diff,
        prior_findings: review_iterations,
        workflow_kind: workflow.trigger_kind,
        feedback_context: feedback_context_text,
        criteria: adversarial_review_criteria
      ).to_s
    end

    def adversarial_review_criteria
      SyrusYml.load_repo(workspace.path).adversarial_review&.criteria || []
    rescue SyrusYml::ParseError, Errno::ENOENT
      []
    end

    def review_issue
      job.synthetic_issue || Struct.new(:title, :body).new(job.issue_title.to_s, job.issue_body.to_s)
    end

    def latest_agentic_diff
      agentic_kind = feedback_workflow? ? "respond" : "implement"
      workflow.steps
        .where(kind: agentic_kind, state: "succeeded")
        .order(:position)
        .last
        &.latest_run
        &.agent_diff
        .presence || raise(StepFailed, "no succeeded #{agentic_kind} diff available for adversarial_review")
    end

    def feedback_workflow?
      FEEDBACK_TRIGGER_KINDS.include?(workflow.trigger_kind)
    end

    def feedback_context_text
      return nil unless feedback_workflow?

      if workflow.trigger_kind == "chat_feedback"
        workflow.artifact("chat_feedback").to_s.presence
      else
        render_pr_comments(Array(workflow.artifact("pr_comments")))
      end
    end

    def render_pr_comments(comments)
      return nil if comments.empty?

      comments.map { |c| render_pr_comment(c) }.join("\n\n")
    end

    def render_pr_comment(c)
      author = c["author"].presence || "reviewer"
      body   = c["body"].to_s
      if c["path"].present?
        "[Inline on #{c["path"]}:#{c["line"]}] @#{author}: #{body}"
      else
        "@#{author}: #{body}"
      end
    end

    def review_iterations
      Array(workflow.artifact("adversarial_review_iterations"))
    end

    def discard_reviewer_workspace_changes
      return unless File.exist?(workspace.path.join(".git"))

      status = GitRunner.new.run("status", "--porcelain", chdir: workspace.path.to_s)
      return if status.strip.empty?

      log("[adversarial_review] discarding uncommitted reviewer workspace changes", kind: "system")
      git = streaming_git
      git.run("restore", "--staged", "--worktree", ".", chdir: workspace.path.to_s)
      git.run("clean", "-fd", chdir: workspace.path.to_s)
    end
  end
end
