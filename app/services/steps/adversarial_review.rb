module Steps
  class AdversarialReview < Base
    FAILURE_SKIP_THRESHOLD = 2

    def call
      workspace.setup
      run.update!(prompt: reviewer_prompt) if run.prompt.blank?

      before_count = review_iterations.size
      log("invoking agent for adversarial_review step (#{workflow.slug}, step ##{step.id}, iteration #{step.iteration})")

      run_agent(prompt: run.prompt,
                required_mcp_tools: %w[submit_adversarial_review],
                disallowed_tools: REVIEW_COLLIDING_TOOLS)
      discard_reviewer_workspace_changes

      workflow.reload
      if review_iterations.size <= before_count
        capture_mcp_sidecar_stderr
        if repeated_review_failures?
          skip_review!("reviewer did not call submit_adversarial_review after #{prior_failed_review_runs} prior failed attempt(s)")
          return
        end

        raise StepFailed, "agent didn't call submit_adversarial_review"
      end
    rescue StandardError => e
      raise unless skippable_review_failure?(e)

      log("[adversarial_review] skipped after reviewer failure: #{e.class}: #{e.message}", kind: "system")
      skip_review!("#{e.class}: #{e.message}")
    end

    private

    def parent_session_id
      return nil if agent_resume_disabled?

      explicit_parent_session_id ||
        workflow.steps
          .where(kind: "adversarial_review", loop_id: step.loop_id)
          .where("iteration < ?", step.iteration)
          .order(iteration: :desc)
          .first&.latest_run&.provider_session&.session_id
    end

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
      Workflow::TriggerKind.feedback_kind_for(workflow.trigger_kind).present?
    end

    def feedback_context_text
      Workflow::FeedbackKind.for(workflow)&.review_text
    end

    def review_iterations
      Array(workflow.artifact("adversarial_review_iterations"))
    end

    def skippable_review_failure?(exception)
      prompt_too_long?(exception) || repeated_review_failures?
    end

    def prompt_too_long?(exception)
      "#{exception.class}: #{exception.message}".match?(/prompt is too long|context.*too long|maximum context|context length/i)
    end

    def repeated_review_failures?
      prior_failed_review_runs >= FAILURE_SKIP_THRESHOLD
    end

    def prior_failed_review_runs
      @prior_failed_review_runs ||= step.runs.where.not(id: run.id).where(state: "failed").count
    end

    def skip_review!(reason)
      iterations = review_iterations
      iterations << {
        "iteration" => step.iteration,
        "critique" => "Adversarial review skipped: #{reason}",
        "verdict" => "approved",
        "skipped" => true,
        "skip_reason" => reason
      }
      workflow.set_artifact!("adversarial_review_iterations", iterations)
      step.details = step.details.to_h.merge(
        "adversarial_review_skipped" => true,
        "adversarial_review_skip_reason" => reason
      )
      step.save!
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
