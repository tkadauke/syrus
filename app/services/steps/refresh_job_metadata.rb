module Steps
  # Agentic feedback step that refreshes canonical Job/PR review metadata.
  class RefreshJobMetadata < Base
    TURN_BUDGET = 25

    def call
      workspace.setup
      run.update!(prompt: prompt.to_s) if run.prompt.blank?

      log("invoking agent for refresh_job_metadata step (#{workflow.slug}, --resume)")
      run_agent(
        prompt: run.prompt,
        max_turns: TURN_BUDGET,
        required_mcp_tools: %w[submit_job_metadata]
      )

      raise StepFailed, "agent didn't call submit_job_metadata" unless workflow.reload.artifact("job_metadata").is_a?(Hash)
    end

    private

    def prompt
      Prompts::RefreshJobMetadata.new(
        job: job,
        current_pr: current_pr,
        prior_summaries: prior_summaries,
        feedback: feedback_text,
        diff: current_diff
      )
    end

    def current_pr
      return if job.pr_number.blank?

      @current_pr ||= GithubClient.for(repository: job.effective_pr_repository, user: job.user)
        .pull_request(job.effective_pr_repository.slug, job.pr_number, bypass_cache: true)
    rescue StandardError => e
      log("refresh_job_metadata: failed to fetch PR ##{job.pr_number}: #{e.class}: #{e.message}")
      nil
    end

    def prior_summaries
      job.workflows
         .where.not(id: workflow.id)
         .order(:created_at)
         .filter_map { |candidate| candidate.artifact("summary").presence || candidate.runs.where.not(agent_summary: [ nil, "" ]).order(:created_at).last&.agent_summary }
    end

    def feedback_text
      case Workflow::TriggerKind.feedback_kind_for(workflow.trigger_kind)
      when :chat_feedback
        workflow.artifact("chat_feedback").to_s
      when :pr_comment
        Array(workflow.artifact("pr_comments")).map { |comment| comment["body"].to_s }.reject(&:blank?).join("\n\n")
      end
    end

    def current_diff
      workflow.steps.where(kind: "respond").order(:position).last&.latest_run&.agent_diff.presence ||
        run.agent_diff.presence ||
        git_diff
    end

    def git_diff
      streaming_git.run("diff", "#{workspace.base_ref}...HEAD", chdir: workspace.path.to_s)
    rescue StandardError => e
      log("refresh_job_metadata: failed to capture diff: #{e.class}: #{e.message}")
      nil
    end
  end
end
