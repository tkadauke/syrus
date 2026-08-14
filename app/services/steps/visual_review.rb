module Steps
  class VisualReview < Base
    def call
      workspace.setup

      if when_files_changed_configured? && !changed_files_match?
        skip_via_pre_filter!
        return
      end

      run.update!(prompt: reviewer_prompt) if run.prompt.blank?

      before_count = review_iterations.size
      log("invoking agent for visual_review step (#{workflow.slug}, step ##{step.id}, iteration #{step.iteration})")

      run_agent(prompt: run.prompt, required_mcp_tools: %w[submit_visual_review])
      discard_reviewer_workspace_changes

      workflow.reload
      if review_iterations.size <= before_count
        capture_mcp_sidecar_stderr
        raise StepFailed, "agent didn't call submit_visual_review"
      end
    end

    private

    def parent_session_id
      return nil if agent_resume_disabled?

      explicit_parent_session_id ||
        workflow.steps
          .where(kind: "visual_review", loop_id: step.loop_id)
          .where("iteration < ?", step.iteration)
          .order(iteration: :desc)
          .first&.latest_run&.provider_session&.session_id
    end

    def reviewer_prompt
      Prompts::VisualReview.new(
        issue: review_issue,
        diff: latest_agentic_diff,
        prior_findings: review_iterations,
        workflow_kind: workflow.trigger_kind,
        feedback_context: feedback_context_text,
        test_plan_recommended: test_plan_artifact["visual_review_recommended"],
        test_plan_reason: test_plan_artifact["visual_review_reason"],
        seed_notes: visual_review_config&.seed_notes
      ).to_s
    end

    def test_plan_artifact
      workflow.artifact("test_plan").to_h
    end

    def visual_review_config
      return @visual_review_config if defined?(@visual_review_config)

      @visual_review_config = begin
        SyrusYml.load_repo(workspace.path).visual_review
      rescue SyrusYml::ParseError, Errno::ENOENT
        nil
      end
    end

    def when_files_changed_configured?
      Array(visual_review_config&.when_files_changed).any?
    end

    def changed_files_match?
      patterns = Array(visual_review_config&.when_files_changed)
      changed_files.any? do |file|
        patterns.any? { |pattern| File.fnmatch(pattern, file, File::FNM_DOTMATCH) }
      end
    end

    def changed_files
      GitRunner.new.run("diff", "--name-only", "#{default_branch_ref}...HEAD", chdir: workspace.path.to_s)
        .split("\n").map(&:strip).reject(&:empty?)
    rescue GitRunner::GitError => e
      log("[visual_review] warning: could not determine changed files: #{e.message}")
      []
    end

    def skip_via_pre_filter!
      log("[visual_review] skipped: no changed files match visual_review.when_files_changed")
      record_skip!("No changed files matched the configured visual_review.when_files_changed patterns.")
    end

    def record_skip!(critique)
      iterations = review_iterations
      iterations << {
        "iteration" => step.iteration,
        "critique" => critique,
        "verdict" => "skipped"
      }
      workflow.set_artifact!("visual_review_iterations", iterations)
    end

    def review_issue
      job.synthetic_issue || Struct.new(:title, :body).new(job.issue_title.to_s, job.issue_body.to_s)
    end

    # Standalone manual visual review workflows (Workflows::ManualVisualReview)
    # have no implement/respond step to read a diff off of — they run the
    # reviewer alone against whatever is already on the branch. Only fall
    # back to a fresh `git diff` when this workflow's chain has no step of
    # that kind at all; when one exists but hasn't produced a diff (still
    # running, failed, or genuinely produced nothing) keep raising so a
    # broken loop iteration surfaces instead of silently reviewing stale state.
    def latest_agentic_diff
      agentic_kind = feedback_workflow? ? "respond" : "implement"
      scope = workflow.steps.where(kind: agentic_kind)

      if scope.exists?
        scope.where(state: "succeeded")
          .order(:position)
          .last
          &.latest_run
          &.agent_diff
          .presence || raise(StepFailed, "no succeeded #{agentic_kind} diff available for visual_review")
      else
        diff_against_default.presence || raise(StepFailed, "no changes to review against #{default_branch_ref}")
      end
    end

    def feedback_workflow?
      Workflow::TriggerKind.feedback_kind_for(workflow.trigger_kind).present?
    end

    def feedback_context_text
      return nil unless feedback_workflow?

      case Workflow::TriggerKind.feedback_kind_for(workflow.trigger_kind)
      when :chat_feedback
        workflow.artifact("chat_feedback").to_s.presence
      when :pr_comment
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
      Array(workflow.artifact("visual_review_iterations"))
    end

    def discard_reviewer_workspace_changes
      return unless File.exist?(workspace.path.join(".git"))

      status = GitRunner.new.run("status", "--porcelain", chdir: workspace.path.to_s)
      return if status.strip.empty?

      log("[visual_review] discarding uncommitted reviewer workspace changes", kind: "system")
      git = streaming_git
      git.run("restore", "--staged", "--worktree", ".", chdir: workspace.path.to_s)
      git.run("clean", "-fd", chdir: workspace.path.to_s)
    end
  end
end
