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
    PUBLILIUS_SYRUS_QUOTES = [
      { latin: "Bis dat qui cito dat.", english: "He gives twice who gives quickly." },
      { latin: "Malum est consilium quod mutari non potest.", english: "It is a bad plan that admits of no modification." },
      { latin: "Deliberandum est diu quod statuendum est semel.", english: "What is decided once must be deliberated long." },
      { latin: "Nimium altercando veritas amittitur.", english: "By too much arguing, truth is lost." },
      { latin: "Dum differt vita transcurrit.", english: "While we delay, life passes by." },
      { latin: "Ex vitio alterius sapiens emendat suum.", english: "The wise man corrects his faults by observing those of others." },
      { latin: "Ibi semper est victoria ubi concordia est.", english: "Where there is unity there is always victory." },
      { latin: "Nemo scit quid possit nisi qui tentavit.", english: "No one knows what they can do until they try." },
      { latin: "Iniuriam qui facturus est iam facit.", english: "One who is about to do an injustice already does it." },
      { latin: "Bona opinio hominum tutior pecunia est.", english: "The good opinion of men is safer than money." },
      { latin: "Furor fit laesa saepius patientia.", english: "Patience when too often injured turns to rage." },
      { latin: "Dum aliquid superest, nihil perisse putandum est.", english: "While something remains, nothing should be thought lost." }
    ].freeze

    class BranchDiverged < StepFailed; end

    def call
      workspace.setup
      verify_coding_handoff_snapshot!
      log("pr_open: checking PR open preconditions (#{workflow.slug})")

      if empty_reconciliation_patch?
        close_empty_reconciliation_pr_if_needed
        close_empty_reconciliation_job!
        return
      end

      log("pr_open: pushing branch and opening PR (#{workflow.slug})")
      push_branch

      if job.pr_number.present?  # idempotent: upstream PR already open (non-fork or post-approval)
        log("pr_open: branch pushed for existing PR ##{job.pr_number}")
        transition_job_to_implemented!
        post_coverage_comment_if_present
        return
      end

      if cross_fork?
        open_fork_review_pr
      elsif fork_to_upstream?
        open_upstream_pr
        post_coverage_comment_if_present
      else
        open_pr
        post_coverage_comment_if_present
      end
    end

    private

    def empty_reconciliation_patch?
      return false unless reconciliation_job?

      git = streaming_git(env: { "GIT_TERMINAL_PROMPT" => "0" })
      base_branch = job.effective_base_branch
      base_ref = reconciliation_comparison_ref(git, base_branch)
      git.run("diff", "--quiet", "#{base_ref}..HEAD", "--", chdir: workspace.path.to_s)
      log("pr_open: reconciliation produced no changes against #{base_branch}")
      true
    rescue GitRunner::GitError => e
      return false if e.exit_status == 1

      raise
    end

    def reconciliation_job?
      return false unless job.epic_id

      epic = Epic.find_by(id: job.epic_id, reconciliation_job_id: job.id)
      epic&.resolved_reconciliation_mode == "pr"
    end

    def reconciliation_comparison_ref(git, base_branch)
      return workspace.base_ref if job.base_on_upstream_default? && base_branch == job.base_default_branch

      ref = "refs/remotes/origin/#{base_branch}"
      git.run(
        "fetch",
        repository.authenticated_url(user: job.user),
        "+refs/heads/#{base_branch}:#{ref}",
        chdir: workspace.path.to_s
      )
      ref
    end

    def close_empty_reconciliation_pr_if_needed
      return if job.pr_number.blank?

      pr_repo = job.effective_pr_repository
      client = GithubClient.for(repository: pr_repo, user: job.user)
      client.add_issue_comment(pr_repo.slug, job.pr_number, empty_reconciliation_pr_comment)
      client.close_pull_request(pr_repo.slug, job.pr_number)
      log("pr_open: closed empty reconciliation PR ##{job.pr_number}")
    end

    def close_empty_reconciliation_job!
      base_branch = job.effective_base_branch
      workflow.set_artifact!("no_pr_reason", {
        "kind" => "empty_reconciliation",
        "message" => "No PR was opened because reconciliation made no additional changes beyond #{base_branch}.",
        "base_branch" => base_branch,
        "detected_at" => Time.current.iso8601
      })
      job.close_with_reason!("no_changes") if job.may_close?
    end

    def empty_reconciliation_pr_comment
      "Syrus is closing this reconciliation PR because the final branch has no diff against the effective stack parent (`#{job.effective_base_branch}`). The reconciliation Job is being closed successfully as `no_changes`."
    end

    def verify_coding_handoff_snapshot!
      return unless workflow.trigger_kind == "coding_handoff"

      snapshot = workflow.artifact("coding_handoff")
      raise StepFailed, "coding handoff metadata is missing" unless snapshot.is_a?(Hash)

      expected_branch = snapshot["handoff_branch"].to_s
      expected_sha = snapshot["head_sha"].to_s
      raise StepFailed, "coding handoff branch is missing from metadata" if expected_branch.blank?
      raise StepFailed, "coding handoff head SHA is missing from metadata" if expected_sha.blank?
      raise StepFailed, "coding handoff branch mismatch: workflow has #{workspace.branch_name}, expected #{expected_branch}" unless workspace.branch_name == expected_branch

      git = streaming_git(env: { "GIT_TERMINAL_PROMPT" => "0" })
      actual_sha = current_head_sha(git)
      raise StepFailed, "coding handoff checkout is stale: HEAD is #{actual_sha}, expected #{expected_sha}" unless actual_sha == expected_sha

      diff = git.run("diff", "--name-only", "#{workspace.base_ref}...HEAD", chdir: workspace.path.to_s).strip
      raise StepFailed, "coding handoff branch has no changes against #{workspace.base_ref}" if diff.blank?
    end

    # Fork → in-instance upstream: open a single PR directly on the upstream
    # (head = fork branch, base = upstream default). The work branch was based
    # off the upstream's default tip (see Job#base_on_upstream_default?), so the
    # diff and PR line up. No staging PR on the fork.
    def open_upstream_pr
      title, body = pr_title_and_body
      upstream = job.base_repository
      upstream_client = GithubClient.for(repository: upstream, user: job.user)
      pr_number = PullRequestOpener.new(
        upstream,
        client: upstream_client,
        head_repository: repository
      ).open(
        branch: workspace.branch_name,
        title: title,
        body: body,
        job: job,
        base: pr_base_branch
      )
      log("pr_open: opened upstream PR #{upstream.slug}##{pr_number} from #{repository.slug} (#{title.inspect})")
      job.update!(
        pr_number: pr_number,
        pr_repository_id: upstream.id,
        branch_name: workspace.branch_name
      )
      transition_job_to_implemented!
      refresh_stack_footer
    end

    # Opens a staging review PR on the fork (feature branch → fork default branch).
    # The operator (or any reviewer) approves this PR; PollForkReviewPrJob detects
    # the approval and calls ForkReviewApprover, which closes this PR and opens
    # the real upstream PR. The fork review PR is a review artifact only — never
    # intended to be merged as a landing step.
    def open_fork_review_pr
      if job.fork_review_pr_number.present?  # idempotent for retry
        log("pr_open: branch pushed for existing fork review PR ##{job.fork_review_pr_number}")
        transition_job_to_implemented!
        return
      end

      title, body = pr_title_and_body
      fork_client = GithubClient.for(repository: repository, user: job.user)
      pr_number = PullRequestOpener.new(repository, client: fork_client).open(
        branch: workspace.branch_name,
        title: fork_review_pr_title(title),
        body: fork_review_pr_body(body),
        job: job,
        base: pr_base_branch
      )
      log("pr_open: opened fork review PR ##{pr_number} on #{repository.slug} (#{fork_review_pr_title(title).inspect})")
      job.update!(
        fork_review_pr_number: pr_number,
        branch_name: workspace.branch_name
      )
      transition_job_to_implemented!
    end

    # Opens a PR on the job's effective target repository (non-fork path).
    def open_pr
      title, body = pr_title_and_body
      target_repo = job.effective_target_repository
      opener_client = GithubClient.for(repository: target_repo, user: job.user)
      pr_number = PullRequestOpener.new(
        target_repo,
        client: opener_client
      ).open(
        branch: workspace.branch_name,
        title: title,
        body: body,
        job: job,
        base: pr_base_branch
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

    def fork_review_pr_title(base_title)
      target_slug = job.target_repository&.slug || "upstream"
      "[Review] #{base_title} — approve to send to #{target_slug}"
    end

    def fork_review_pr_body(base_body)
      target_slug = job.target_repository&.slug || "upstream"
      header = <<~HEADER.strip
        > **Staging review** — approve or merge this PR to create a pull request on #{target_slug}.
        > This PR is a review artifact and will not be merged into this repository as a landing step.
      HEADER
      "#{header}\n\n#{base_body}"
    end

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
      raise unless job.pr_number.present? && push_rejected?(e)

      record_branch_divergence!(git, e.message)
      raise BranchDiverged, branch_divergence_message
    end

    def pr_base_branch
      RebaseTarget.branch_for(job: job, workflow: workflow)
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
      parts << latin_quote_footer
      parts << ""
      parts << "---"
      implement_run = workflow.steps.where(kind: "implement").last&.latest_run
      parts << attribution_footer(implement_run)
      PrCostFooter.apply(PrStackFooter.apply(parts.join("\n"), job), job)
    end

    def cross_fork?
      job.in_fork_review_mode?
    end

    def fork_to_upstream?
      job.base_on_upstream_default?
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

    def post_coverage_comment_if_present
      pr_comment_body = workflow.artifact("coverage")&.[]("pr_comment_body")
      return unless pr_comment_body.present?

      pr_number = job.pr_number
      return unless pr_number.present?

      pr_repo   = job.effective_pr_repository
      client    = GithubClient.for(repository: pr_repo, user: job.user)
      repo_slug = pr_repo.slug

      existing = client.pr_issue_comments(repo_slug, pr_number).find do |comment|
        comment.body.to_s.include?(CoverageReport::PrCommentFormatter::MARKER)
      end

      if existing
        client.update_issue_comment(repo_slug, existing.id, pr_comment_body)
        log("[pr_open] updated coverage comment ##{existing.id} on PR ##{pr_number}")
      else
        client.add_issue_comment(repo_slug, pr_number, pr_comment_body)
        log("[pr_open] posted coverage comment on PR ##{pr_number}")
      end
    rescue => e
      log("[pr_open] failed to post coverage comment: #{e.class}: #{e.message}")
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
        "syrus checkout #{job.slug}",
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

    def latin_quote_footer
      q = PUBLILIUS_SYRUS_QUOTES.sample
      "> *\"#{q[:latin]}\"* — [Publilius Syrus](https://en.wikipedia.org/wiki/Publilius_Syrus)"
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
