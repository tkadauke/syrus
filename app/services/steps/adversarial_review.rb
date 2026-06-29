module Steps
  class AdversarialReview < Base
    def call
      workspace.setup
      run.update!(prompt: reviewer_prompt) if run.prompt.blank?

      before_count = review_iterations.size
      log("invoking agent for adversarial_review step (#{workflow.slug}, step ##{step.id}, iteration #{step.iteration})")

      run_agent(prompt: run.prompt)
      discard_reviewer_workspace_changes

      workflow.reload
      if review_iterations.size <= before_count
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

    def reviewer_prompt
      Prompts::AdversarialReview.new(
        issue: review_issue,
        diff: latest_implement_diff,
        prior_findings: review_iterations
      ).to_s
    end

    def review_issue
      job.synthetic_issue || Struct.new(:title, :body).new(job.issue_title.to_s, job.issue_body.to_s)
    end

    def latest_implement_diff
      workflow.steps
        .where(kind: "implement", state: "succeeded")
        .order(:position)
        .last
        &.latest_run
        &.agent_diff
        .presence || raise(StepFailed, "no succeeded implement diff available for adversarial_review")
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
