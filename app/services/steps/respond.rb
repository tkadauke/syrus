module Steps
  # First step of PrFeedback workflow. Agent receives the new
  # review comments + the original issue/diff context (via
  # Prompts::PrFeedback), addresses each piece of feedback,
  # commits to the existing branch.
  #
  # Cross-workflow boundary: NO --resume from the prior Initial
  # workflow's session. The prompt carries the context the agent
  # needs.
  class Respond < Base
    def call
      perform_agentic_change_step(
        log_message: "invoking agent for respond step (#{workflow.slug}, #{workflow.trigger_kind})",
        commit_message: "Syrus respond step (will be rewritten by summarize_amend)"
      ) do
        run.update!(prompt: compose_prompt) if run.prompt.blank?
      end
    end

    private

    def compose_prompt
      prompt = workflow.trigger_kind == "chat_feedback" ? compose_chat_feedback_prompt : compose_pr_feedback_prompt

      append_grade_failure_feedback(prompt)
    end

    def compose_pr_feedback_prompt
      comments = workflow.artifact("pr_comments") || []
      cutoff = parse_cutoff(workflow.artifact("feedback_cutoff"))

      Prompts::PrFeedback.new(
        issue: issue_for_prompt,
        comments: hydrate_comments(comments),
        cutoff: cutoff,
        prior_summaries: prior_feedback_summaries(%w[pr_comment]),
        recent_commits: recent_branch_commits,
        epic: job.epic,
        job: job,
        user: job.user,
        repository_ids: [ job.repository_id ]
      ).to_s
    end

    def compose_chat_feedback_prompt
      Prompts::ChatFeedback.new(
        issue: issue_for_prompt,
        feedback: workflow.artifact("chat_feedback").to_s,
        prior_summaries: prior_feedback_summaries(Workflow::TriggerKind.feedback_values),
        recent_commits: recent_branch_commits,
        epic: job.epic,
        job: job
      ).to_s
    end

    def issue_for_prompt
      job.issue? ? GithubClient.for(repository: repository, user: job.user).fetch_issue(repository.slug, job.issue_number) : job.synthetic_issue
    end

    def parse_cutoff(raw)
      return nil if raw.blank?
      Time.zone.parse(raw.to_s)
    rescue ArgumentError
      nil
    end

    # Pull agent_summary strings off every prior pr_comment Workflow
    # on this Job that produced one, in chronological order. The
    # current workflow is excluded — the summary it will produce is
    # not relevant to this Step's own prompt. Skips Workflows that
    # never reached summarize_amend (no agent_summary on any Run).
    def prior_feedback_summaries(trigger_kinds)
      prior_workflows = job.workflows
                           .where(trigger_kind: trigger_kinds)
                           .where("id < ?", workflow.id)
                           .order(:created_at)
                           .to_a
      prior_workflows.map { |wf| summary_for(wf) }.compact
    end

    def summary_for(wf)
      wf.steps
        .where(kind: "summarize_amend")
        .order(:position)
        .each do |step|
          step.runs.order(:created_at).each do |r|
            return r.agent_summary if r.agent_summary.present?
          end
        end
      nil
    end

    # The polling job stashes raw comment data on the workflow
    # artifact when instantiating; rehydrate it into objects that
    # Prompts::PrFeedback expects (responds to #user.login,
    # #body, #path, etc.). Tolerant — anything missing renders
    # as a generic string.
    def hydrate_comments(raw)
      raw.map do |c|
        Struct.new(:user, :body, :path, :line, :diff_hunk, :created_at).new(
          Struct.new(:login).new(c["author"] || "reviewer"),
          c["body"], c["path"], c["line"], c["diff_hunk"], c["created_at"]
        )
      end
    end
  end
end
