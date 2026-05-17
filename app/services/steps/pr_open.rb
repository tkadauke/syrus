module Steps
  # Final step of Initial / Retry workflows. Non-agentic. Pushes
  # the workflow branch to origin, then opens a PR against
  # default. Reads pr_title / pr_body from workflow.artifacts (set
  # by Steps::Summarize) and falls through to PrSummarizer or a
  # template if those are missing — same degradation hierarchy
  # the legacy RunJob has, just driven from artifacts now.
  #
  # Idempotent: if the Job already has a pr_number (retry on a
  # Job that already opened a PR), skip PR creation and just push
  # the new commits.
  class PrOpen < Base
    def call
      workspace.setup
      log("pr_open: pushing branch and opening PR (workflow ##{workflow.id})")

      push_branch
      if job.pr_number.present?  # idempotent for retry
        job.mark_implemented! if job.may_mark_implemented?
        return
      end

      title, body = pr_title_and_body
      pr_number = PullRequestOpener.new(repository).open(
        branch: workspace.branch_name,
        title: title,
        body: body,
        job: job
      )
      job.update!(pr_number: pr_number, branch_name: workspace.branch_name)
      job.mark_implemented! if job.may_mark_implemented?
      refresh_stack_footer
      log("pr_open: opened PR ##{pr_number} (#{title.inspect})")
    end

    private

    def push_branch
      git = streaming_git(env: { "GIT_TERMINAL_PROMPT" => "0" })
      push_url = repository.authenticated_push_url(GithubClient.for(repository: repository, user: job.user).access_token)
      git.run("push", push_url, "HEAD:refs/heads/#{workspace.branch_name}",
              chdir: workspace.path.to_s)
    end

    # Three-tier degradation, same shape as legacy
    # RunJob#open_pull_request_if_missing:
    #
    #   1. workflow.artifacts (preferred — agent-authored via
    #      submit_summary in the summarize step)
    #   2. PrSummarizer second-shot through the Workflow's agent
    #      provider (safety net if summarize didn't produce artifacts)
    #   3. templated default (last resort)
    def pr_title_and_body
      title, body = pr_title_and_body_from_artifacts
      title, body = pr_title_and_body_from_summarizer if title.blank? || body.blank?
      [ (title.presence || template_title), (body.presence || template_body) ].tap { |t, b|
        return [ t, compose_body(b) ]
      }
    end

    def pr_title_and_body_from_artifacts
      title = workflow.artifact("pr_title")
      body  = workflow.artifact("pr_body")
      return [ nil, nil ] if title.blank? || body.blank?
      log("[pr_open] using artifacts.pr_title: #{title.inspect}")
      [ title, body ]
    end

    def pr_title_and_body_from_summarizer
      issue = pr_summarizer_context
      log("[pr_open] no artifacts; falling back to PrSummarizer second-shot")
      summary = PrSummarizer.new(
        issue: issue,
        diff: run.agent_diff || workflow.steps.where(kind: "implement").last&.latest_run&.agent_diff,
        agent: agent_adapter,
        log_sink: ->(chunk, kind: nil) { log("[summarizer] #{chunk}", kind: kind) }
      ).call
      return [ nil, nil ] unless summary.success?
      log("[pr_open] using summarizer-authored title: #{summary.title.inspect}")
      [ summary.title, summary.body ]
    rescue StandardError => e
      log("[pr_open] summarizer failed: #{e.class}: #{e.message} — falling through to template")
      [ nil, nil ]
    end

    def pr_summarizer_context
      job.cron? ? job.synthetic_issue : GithubClient.for(repository: repository, user: job.user).fetch_issue(repository.slug, job.issue_number)
    end

    def compose_body(body)
      parts = []
      parts << "Closes ##{job.issue_number}" if job.issue?
      parts << "" if job.issue?
      parts << body
      if job.direct? && (handle = BotIdentity.github_handle(job.user))
        parts << ""
        parts << "Triggered by @#{handle}"
      end
      parts << ""
      parts << "---"
      implement_run = workflow.steps.where(kind: "implement").last&.latest_run
      parts << attribution_footer(implement_run)
      PrCostFooter.apply(PrStackFooter.apply(parts.join("\n"), job), job)
    end

    def refresh_stack_footer
      return unless job.parent_job.present? || job.stack_children.exists?

      client = GithubClient.for(repository: repository, user: job.user)
      [ job.parent_job, job ].compact.uniq.each do |stack_job|
        next if stack_job.pr_number.blank?

        pr = client.pull_request(repository.slug, stack_job.pr_number, bypass_cache: true)
        body = PrCostFooter.apply(PrStackFooter.apply(pr.body.to_s, stack_job), stack_job)
        client.update_pull_request_body(repository.slug, stack_job.pr_number, body)
      end
    end

    def attribution_footer(implement_run)
      provider = implement_run&.agent_provider.presence || workflow.agent_provider.presence
      author = provider.present? ? provider.titleize : "an LLM"

      details = []
      details << "Run took #{implement_run&.agent_turns || '?'} turn(s)" unless provider == "codex"
      details << "trigger=#{workflow.trigger_kind}"

      "*Authored by #{author} (#{details.join(', ')}). Review carefully.*"
    end

    def template_title
      if job.cron?
        "[syrus] scheduled: #{job.scheduled_task&.name || "task ##{job.scheduled_task_id}"}"
      else
        "[syrus] #{repository.slug}##{job.issue_number}"
      end
    end

    def template_body
      if job.cron?
        task_name = job.scheduled_task&.name || "##{job.scheduled_task_id}"
        "Opened by a Syrus scheduled task (`#{task_name}`).\n\nReview the diff carefully — this PR was authored by an LLM."
      else
        "Closes ##{job.issue_number}\n\nOpened by Syrus from issue ##{job.issue_number}.\n\nReview the diff carefully — this PR was authored by an LLM."
      end
    end
  end
end
