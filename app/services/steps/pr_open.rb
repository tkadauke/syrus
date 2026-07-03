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
    class BranchDiverged < StepFailed; end

    def call
      workspace.setup
      log("pr_open: pushing branch and opening PR (#{workflow.slug})")

      push_branch
      if job.pr_number.present?  # idempotent for retry
        log("pr_open: branch pushed for existing PR ##{job.pr_number}")
        transition_job_to_implemented!
        return
      end

      title, body = pr_title_and_body
      target_repo = job.effective_target_repository
      opener_client = GithubClient.for(repository: target_repo, user: job.user)
      pr_number = PullRequestOpener.new(
        target_repo,
        client: opener_client,
        head_repository: cross_fork? ? repository : nil
      ).open(
        branch: workspace.branch_name,
        title: title,
        body: body,
        job: job
      )
      log("pr_open: opened PR ##{pr_number} (#{title.inspect})")
      job.update!(
        pr_number: pr_number,
        pr_repository_id: target_repo.id,
        branch_name: workspace.branch_name
      )
      transition_job_to_implemented!
      refresh_stack_footer
    end

    private

    # AASM events on Job mutate in-memory state via the after-callback but
    # don't persist; the save! is required for the transition to land in
    # the DB. Without it, the in-memory mutation also pre-empts
    # Workflow#propagate_succeed_to_job!'s `return unless job.running?`
    # guard, so the workflow-level catch-all never saves either.
    def transition_job_to_implemented!
      return unless job.may_mark_implemented?

      job.notify_job_implemented_on_transition = true
      job.mark_implemented!
      job.save!
    ensure
      job.notify_job_implemented_on_transition = false if job
    end

    def push_branch
      git = streaming_git(env: { "GIT_TERMINAL_PROMPT" => "0" })
      push_url = repository.authenticated_push_url(GithubClient.for(repository: repository, user: job.user).access_token)
      verify_existing_pr_branch_not_diverged!(git, push_url) if job.pr_number.present?
      git.run("push", push_url, "HEAD:refs/heads/#{workspace.branch_name}",
              chdir: workspace.path.to_s)
    rescue GitRunner::GitError => e
      raise unless job.pr_number.present? && non_fast_forward_push?(e)

      record_branch_divergence!(git, e.message)
      raise BranchDiverged, branch_divergence_message
    end

    def verify_existing_pr_branch_not_diverged!(git, push_url)
      remote_sha = fetch_remote_branch!(git, push_url)
      return if remote_sha.blank?

      local_sha = current_head_sha(git)
      return if remote_sha == local_sha
      return if ancestor?(git, remote_sha, "HEAD")

      record_branch_divergence!(git, "remote PR branch moved before push", remote_sha: remote_sha, local_sha: local_sha)
      raise BranchDiverged, branch_divergence_message
    end

    def fetch_remote_branch!(git, push_url)
      branch = workspace.branch_name
      git.run(
        "fetch", push_url, "+refs/heads/#{branch}:refs/remotes/origin/#{branch}",
        chdir: workspace.path.to_s
      )
      git.run("rev-parse", "refs/remotes/origin/#{branch}", chdir: workspace.path.to_s).strip
    rescue GitRunner::GitError => e
      return nil if e.output.to_s.match?(/couldn't find remote ref|could not find remote ref|fatal:.*remote ref/i)

      raise
    end

    def ancestor?(git, ancestor, descendant)
      git.run("merge-base", "--is-ancestor", ancestor, descendant, chdir: workspace.path.to_s)
      true
    rescue GitRunner::GitError
      false
    end

    def record_branch_divergence!(git, message, remote_sha: nil, local_sha: nil)
      workflow.set_artifact!("branch_divergence", {
        "branch" => workspace.branch_name,
        "remote_sha" => remote_sha.presence || remote_branch_sha(git),
        "local_sha" => local_sha.presence || current_head_sha(git),
        "detected_at" => Time.current.iso8601,
        "message" => message.to_s
      }.compact)
      artifact = workflow.artifact("branch_divergence")
      log("pr_open: branch diverged for #{workspace.branch_name}; remote=#{artifact['remote_sha']} local=#{artifact['local_sha']}")
    end

    def remote_branch_sha(git)
      git.run("rev-parse", "refs/remotes/origin/#{workspace.branch_name}", chdir: workspace.path.to_s).strip
    rescue GitRunner::GitError
      nil
    end

    def current_head_sha(git)
      git.run("rev-parse", "HEAD", chdir: workspace.path.to_s).strip
    end

    def non_fast_forward_push?(error)
      error.output.to_s.match?(/non-fast-forward|fetch first|rejected|stale info/i)
    end

    def branch_divergence_message
      "PR branch changed before Syrus could push #{workflow.slug}; choose whether to retry from the current PR branch or replace it with this workflow's output."
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
      if (testing = testing_section).present?
        parts << ""
        parts << testing
      end
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

    def cross_fork?
      job.target_repository_id.present? && job.target_repository_id != job.repository_id
    end

    def refresh_stack_footer
      return unless job.parent_job.present? || job.stack_children.exists?

      [ job.parent_job, job ].compact.uniq.each do |stack_job|
        next if stack_job.pr_number.blank?

        pr_repo = stack_job.effective_pr_repository
        client = GithubClient.for(repository: pr_repo, user: job.user)
        pr = client.pull_request(pr_repo.slug, stack_job.pr_number, bypass_cache: true)
        body = PrCostFooter.apply(PrStackFooter.apply(pr.body.to_s, stack_job), stack_job)
        client.update_pull_request_body(pr_repo.slug, stack_job.pr_number, body)
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

    def testing_section
      test_plan = workflow.artifact("test_plan")
      return if test_plan.blank?

      steps = Array(test_plan["steps"] || test_plan[:steps]).map(&:to_s).map(&:strip).reject(&:empty?)
      notes = (test_plan["notes"] || test_plan[:notes]).to_s.strip
      return if steps.empty? && notes.blank?

      lines = [
        "## Test Plan",
        "",
        "```sh",
        "syrus checkout JOB-#{job.id}",
        "```",
        ""
      ]
      steps.each { |step| lines << "- #{step}" }
      if notes.present?
        lines << ""
        lines << notes
      end
      lines.join("\n")
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
