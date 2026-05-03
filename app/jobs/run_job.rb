class RunJob < ApplicationJob
  queue_as :default

  # One Run at a time per Job. Per-Job (not per-repo) is the right
  # granularity: each Run gets its own worktree under
  # $SYRUS_DATA_ROOT/worktrees/<run_id>/ and works on its own branch
  # (one branch per Job), so two Runs on different Jobs in the same
  # repo never collide. The collision risk is *within* a Job — two
  # follow-ups racing on the same branch — which the per-Job key
  # prevents. (Worth keeping an eye on: simultaneous initial Runs on
  # different Jobs in a fresh repo race to create the bare clone.
  # First-write-wins is a one-time thing per repo and recovers on
  # retry; not worth a separate global lock unless it bites.)
  limits_concurrency to: 1, key: ->(run_id) {
    "job:#{::Run.where(id: run_id).pick(:job_id)}"
  }

  discard_on ActiveRecord::RecordNotFound

  class CancelledMidRun < StandardError; end
  class AgentRunFailed < StandardError; end

  # Test seam — let specs swap in a fake runner without exec'ing claude.
  class << self
    attr_accessor :agent_runner
  end

  def perform(run_id)
    @run = ::Run.find(run_id)
    @job = @run.job
    return if @run.terminal?
    # Rebase Runs are independent of Job lifecycle — they exist to keep
    # an existing PR's branch mergeable, including for preempted (closed)
    # Jobs where the PR is external. Skip the closed-Job guard for them.
    return if @job.closed? && !@run.rebase?

    if @run.running?
      # A previous worker called start! then died without a rescue/ensure.
      # The only safe path forward is to fail this run so the operator can
      # replay it — re-running from the middle of an unknown state isn't safe.
      @run.agent_outcome = "worker_died"
      @run.fail!
      @run.save!
      log("run abandoned — worker died mid-execution; use Replay to retry")
      return
    end

    @run.start!
    @run.save!  # AASM after-callbacks set started_at; persist it.
    @job.update!(started_at: Time.current) if @job.started_at.nil?

    log("starting #{@run.trigger_kind} run #{@run.id} for #{@job.repository.slug}##{@job.issue_number}")

    # External rebase: the PR head branch isn't recorded on the Job.
    # Resolve it from the PR before workspace setup so JobWorkspace can
    # check it out via the existing-branch path.
    resolve_branch_for_rebase if @run.rebase? && @job.branch_name.blank?

    @workspace = JobWorkspace.new(@run, git: streaming_git)
    @workspace.setup
    # Persist whenever it differs — covers initial-run setup AND the
    # recovery case where a previous initial died before pushing,
    # leaving a stale Job.branch_name without an origin counterpart.
    @job.update!(branch_name: @workspace.branch_name) if @job.branch_name != @workspace.branch_name
    abort_if_cancelled!

    # Resume Runs need the prior session's JSONL on disk under the
    # current worktree's project-encoded path before claude --resume
    # can find it.
    restore_claude_session if @run.resume?

    no_changes = false

    if @run.rebase?
      rebase_and_force_push
    else
      result = run_agent_and_commit
      abort_if_cancelled!

      if result == :no_changes
        # Cron Jobs only path: agent surveyed and found nothing to do.
        # No commit, no push, no PR. The Run still succeeds (the cron
        # tick fired and produced its expected outcome) and the parent
        # Job closes immediately, which the scheduled-task tracker
        # interprets as a successful no-op.
        log("[scheduled] no changes — cron Job closing as no_changes")
        no_changes = true
      else
        push_branch
        abort_if_cancelled!
        open_pull_request_if_missing
      end
    end

    schedule_mergeability_recheck unless no_changes

    @run.succeed!
    @run.save!
    log(complete_message)

    finalize_cron_job_no_changes if @job.cron? && no_changes
  rescue CancelledMidRun
    log("cancelled mid-run")
  rescue StandardError => e
    log("FAIL: #{e.class}: #{e.message}")
    if @run&.may_fail?
      @run.fail!
      @run.save!
    end
    @job&.record_run_failure! unless @run&.rebase?
    raise
  ensure
    @workspace&.cleanup
  end

  private

  def abort_if_cancelled!
    raise CancelledMidRun if @run.reload.cancelled?
    # Rebase Runs ignore Job-closure: they're independent of the Job
    # lifecycle (a preempted Job's external PR can still need rebases).
    raise CancelledMidRun if @job.reload.closed? && !@run.rebase?
  end

  def streaming_git(env: {})
    GitRunner.new(log_sink: ->(line) { log(line.chomp) }, env: env)
  end

  # We just pushed (or force-pushed). Mergeability cached on the Job
  # is now stale: badge says "needs rebase" until PollAllRebasesJob's
  # next 15-min tick. Schedule a focused PollRebaseJob with a short
  # delay so GitHub has time to recompute, then the cache update
  # broadcasts a refresh and the show page morphs the badge live.
  MERGEABILITY_RECHECK_DELAY = 30.seconds

  def schedule_mergeability_recheck
    return unless @job.pr_number.present? || @job.external_pr_number.present?
    PollRebaseJob.set(wait: MERGEABILITY_RECHECK_DELAY).perform_later(@job.id)
  end

  def run_agent_and_commit
    prompt = @run.prompt.presence || compose_main_prompt
    @run.update!(prompt: prompt) if @run.prompt.blank?

    target_label = @job.cron? ? "scheduled task ##{@job.scheduled_task_id}" : "#{@job.repository.slug}##{@job.issue_number}"
    log("invoking agent for #{target_label} (run #{@run.id}, trigger=#{@run.trigger_kind})")

    result = with_mcp_config do |mcp_config_path|
      AgentInvocation.new(
        @workspace.path,
        prompt: prompt,
        oauth_token: @job.user.claude_oauth_token,
        log_sink: ->(chunk) { log(chunk) },
        runner: self.class.agent_runner,
        max_turns: @job.user.agent_max_turns,
        mcp_config: mcp_config_path,
        resume_session_id: @run.parent_session_id
      ).run
    end

    persist_agent_metadata(result)
    persist_claude_session(result)

    raise AgentRunFailed, "agent timed out" if result.timed_out
    raise AgentRunFailed, "agent reported #{result.outcome || 'error'}" if result.is_error
    raise AgentRunFailed, "agent exited #{result.exit_status}" unless result.success?

    commit_agent_changes
    diff = capture_diff_against_default

    if diff.blank?
      # For cron Jobs "no diff" is the explicit happy path of an
      # uneventful tick — the agent surveyed and decided there's
      # nothing worth doing. Caller short-circuits push/PR steps.
      return :no_changes if @job.cron?
      raise AgentRunFailed, "agent produced no changes"
    end

    @run.update!(agent_diff: diff, head_sha: head_sha)
    :committed
  end

  # Writes a per-run mcp.json tempfile and yields its path to the
  # block. The agent (claude) reads it via --mcp-config and spawns
  # bin/syrus-mcp-sidecar over stdio, scoped to this run via --run-id.
  def with_mcp_config
    require "tempfile"
    Tempfile.create([ "syrus-mcp-#{@run.id}-", ".json" ]) do |f|
      f.write({
        mcpServers: {
          syrus: {
            type: "stdio",
            command: Rails.root.join("bin/syrus-mcp-sidecar").to_s,
            args: [ "--run-id", @run.id.to_s ],
            env: {}
          }
        }
      }.to_json)
      f.flush
      yield f.path
    end
  end

  # Rebase Runs: skip commit_agent_changes (the rebase rewrites
  # history, not the working tree). Detect HEAD-sha movement to
  # confirm the agent actually rebased; force-push-with-lease so we
  # don't clobber an in-flight push from elsewhere. No PR opening —
  # the PR already exists.
  def rebase_and_force_push
    prompt = @run.prompt.presence || compose_rebase_prompt
    @run.update!(prompt: prompt) if @run.prompt.blank?

    pre_sha = head_sha
    log("rebase pre-sha: #{pre_sha}")

    result = with_mcp_config do |mcp_config_path|
      AgentInvocation.new(
        @workspace.path,
        prompt: prompt,
        oauth_token: @job.user.claude_oauth_token,
        log_sink: ->(chunk) { log(chunk) },
        runner: self.class.agent_runner,
        max_turns: @job.user.agent_max_turns,
        mcp_config: mcp_config_path,
        resume_session_id: @run.parent_session_id
      ).run
    end

    persist_agent_metadata(result)
    persist_claude_session(result)

    raise AgentRunFailed, "agent timed out" if result.timed_out
    raise AgentRunFailed, "agent reported #{result.outcome || 'error'}" if result.is_error
    raise AgentRunFailed, "agent exited #{result.exit_status}" unless result.success?

    post_sha = head_sha
    if pre_sha == post_sha
      raise AgentRunFailed, "rebase did not move HEAD (agent aborted or did nothing)"
    end

    log("rebase post-sha: #{post_sha}")
    diff = capture_diff_against_default
    @run.update!(agent_diff: diff, head_sha: post_sha)

    push_branch_force
  end

  def push_branch_force
    git = streaming_git(env: { "GIT_TERMINAL_PROMPT" => "0" })
    push_url = @job.repository.authenticated_push_url(@job.user.github_token)
    # Plain --force, not --force-with-lease: the worktree clones from
    # the bare cache and doesn't carry a local-tracking ref for the
    # remote branch, so --force-with-lease has no recorded "expected"
    # value and rejects the push. We own the branch (`syrus/...` for
    # internal Runs, the PR's head for external Runs we're rebasing
    # on the operator's behalf) and Syrus is the only writer, so a
    # bare --force is safe.
    git.run("push", "--force", push_url,
            "HEAD:refs/heads/#{@workspace.branch_name}",
            chdir: @workspace.path.to_s)
  end

  def compose_rebase_prompt
    Prompts::Rebase.new(
      repo_slug: @job.repository.slug,
      branch_name: @job.branch_name || rebase_pr_head_ref,
      base_branch: @job.repository.default_branch,
      pr_number: rebase_pr_number
    ).to_s
  end

  def rebase_pr_number
    @job.pr_number || @job.external_pr_number
  end

  def rebase_pr_head_ref
    @rebase_pr_head_ref ||= GithubClient.for(@job.user).pull_request(@job.repository.slug, rebase_pr_number).head.ref
  end

  # Look up the external PR's head branch and stash it on the Job so
  # JobWorkspace's normal "existing-branch checkout" path takes over.
  def resolve_branch_for_rebase
    return unless rebase_pr_number
    @job.update!(branch_name: rebase_pr_head_ref)
  end

  def complete_message
    if @run.rebase?
      "rebase complete — branch force-pushed"
    elsif @job.cron? && @job.pr_number.blank?
      "scheduled run complete — no changes (cron tick recorded)"
    elsif @run.initial?
      "run complete — PR ##{@job.pr_number} opened"
    else
      "run complete — follow-up commit pushed"
    end
  end

  # Initial Runs on issue Jobs get the issue title + body via
  # Prompts::Initial. Cron Jobs arrive with @run.prompt already
  # rendered by PollScheduledTasksJob (variables expanded at fire
  # time). Resume Runs get a continuation nudge. Follow-up Runs
  # (pr_comment, ci_failure, replay, manual) likewise arrive with
  # @run.prompt already composed.
  def compose_main_prompt
    return Prompts::Resume.new.to_s if @run.resume?
    raise ArgumentError, "cron Run reached compose_main_prompt with blank prompt" if @job.cron?
    issue = GithubClient.for(@job.user).fetch_issue(@job.repository.slug, @job.issue_number)
    persist_issue_metadata(issue)
    Prompts::Initial.new(issue: issue).to_s
  end

  # Bookkeeping after a successful cron Run that produced no diff.
  # The Job has no PR to wait on, so close it immediately with a
  # distinct closure_reason ("no_changes"). The Job#close transition
  # callback handles propagating the success up to the parent
  # ScheduledTask.
  def finalize_cron_job_no_changes
    @job.close_with_reason!("no_changes") if @job.may_close?
  end

  def persist_issue_metadata(issue)
    @job.update!(issue_title: issue.title, issue_body: issue.body)
  end

  def persist_agent_metadata(result)
    updates = {}
    updates[:agent_turns] = result.turns if result.turns
    updates[:agent_outcome] = result.outcome if result.outcome
    @run.update!(updates) if updates.any?
  end

  # Capture the JSONL Claude Code wrote during the run so the same
  # session can be resumed later from a different worker pod. Best-
  # effort: if the file isn't there (worker died before claude wrote
  # it, claude version that doesn't write JSONL, etc.), log and
  # move on — Resume just won't be available for this Run.
  def persist_claude_session(result)
    return unless result.session_id
    path = ClaudeSession.canonical_path_for(
      home: ENV.fetch("HOME"),
      cwd: @workspace.path,
      session_id: result.session_id
    )
    unless File.exist?(path)
      log("[claude_session] no JSONL at #{path} — Resume won't be available for this Run")
      return
    end
    ClaudeSession.create!(run: @run, session_id: result.session_id, transcript_jsonl: File.read(path))
    log("[claude_session] captured #{result.session_id} (#{File.size(path)} bytes)")
  rescue StandardError => e
    log("[claude_session] capture failed: #{e.class}: #{e.message}")
  end

  # Restore the prior Run's JSONL to the new worktree's project
  # directory so claude --resume can find it. Path encoding matches
  # claude-code: cwd "/x/y/z" → "-x-y-z".
  def restore_claude_session
    source = ClaudeSession.find_by(session_id: @run.parent_session_id)
    unless source
      log("[claude_session] parent_session_id #{@run.parent_session_id} not found — resuming may fail")
      return
    end
    path = ClaudeSession.canonical_path_for(
      home: ENV.fetch("HOME"),
      cwd: @workspace.path,
      session_id: source.session_id
    )
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, source.transcript_jsonl)
    log("[claude_session] restored #{source.session_id} to #{path}")
  end

  def commit_agent_changes
    chdir = @workspace.path.to_s
    git = streaming_git
    status = git.run("status", "--porcelain", chdir: chdir)
    return if status.strip.empty?

    git.run("add", "-A", chdir: chdir)
    git.run(
      "-c", "user.name=Syrus",
      "-c", "user.email=syrus@noreply.invalid",
      "commit", "-m", commit_message,
      chdir: chdir
    )
  end

  def commit_message
    @run.reload
    return @run.agent_pr_title if @run.agent_pr_title.present?

    if @job.cron?
      "Syrus scheduled task: #{@job.scheduled_task&.name || "##{@job.scheduled_task_id}"}"
    elsif @run.initial?
      "Syrus agent for #{@job.repository.slug}##{@job.issue_number}"
    else
      "Syrus #{@run.trigger_kind} for #{@job.repository.slug}##{@job.issue_number}"
    end
  end

  # Three-dot diff (`main...HEAD`) — the same view GitHub's "Files
  # changed" tab shows. It's `git diff $(merge-base main HEAD) HEAD`,
  # so it captures only what *this branch* contributed since it
  # diverged from default. Two-dot (`main..HEAD`) would also include
  # commits that landed on main after the branch was opened, rendered
  # as spurious "deletions" — which made follow-up Run diffs look
  # gigantic when main moved forward.
  def capture_diff_against_default
    base = @job.repository.default_branch
    GitRunner.new.run("diff", "#{base}...HEAD", chdir: @workspace.path.to_s)
  end

  def head_sha
    GitRunner.new.run("rev-parse", "HEAD", chdir: @workspace.path.to_s).strip
  end

  def push_branch
    git = streaming_git(env: { "GIT_TERMINAL_PROMPT" => "0" })
    push_url = @job.repository.authenticated_push_url(@job.user.github_token)
    git.run("push", push_url, "HEAD:refs/heads/#{@workspace.branch_name}", chdir: @workspace.path.to_s)
  end

  # Open a PR whenever the Job doesn't have one yet, regardless of which
  # Run is doing the pushing. Most often that's the initial Run, but if
  # an initial Run died before pushing and a replay Run took over and
  # succeeded, the replay needs to open the PR too — otherwise we end up
  # with a branch on origin and no PR pointing at it.
  def open_pull_request_if_missing
    return if @job.pr_number.present?

    title, body = pr_title_and_body_from_agent ||
                  pr_title_and_body_from_summarizer ||
                  [ template_title, template_body ]

    pr_number = PullRequestOpener.new(@job.repository).open(
      branch: @workspace.branch_name,
      title: title,
      body: body
    )
    @job.update!(pr_number: pr_number)
  end

  # Path 1 (preferred): the agent called the `submit_summary` MCP tool
  # during the run, so the sidecar persisted a title + body on Run.
  def pr_title_and_body_from_agent
    @run.reload
    return nil unless @run.agent_pr_title.present? && @run.agent_pr_body.present?
    log("[mcp] using agent-submitted title: #{@run.agent_pr_title.inspect}")
    [ @run.agent_pr_title, compose_body(@run.agent_pr_body) ]
  end

  # Path 2 (fallback): single-shot claude call against the diff.
  def pr_title_and_body_from_summarizer
    summary = summarize_for_pr
    return nil unless summary.success?
    log("[summarizer] using agent-authored title: #{summary.title.inspect}")
    [ summary.title, compose_body(summary.body) ]
  end

  # Asks claude to author a clean PR title + body. For issue Jobs we
  # pass the GitHub issue as context; for cron Jobs we pass a synthetic
  # "issue" struct built from the ScheduledTask so PrSummarizer's
  # prompt template still works without code changes. Never let
  # failures bubble — any error path falls back to template_*.
  def summarize_for_pr
    context = pr_summarizer_context
    log("[summarizer] composing PR title and body…")
    PrSummarizer.new(
      issue: context,
      diff: @run.agent_diff,
      oauth_token: @job.user.claude_oauth_token,
      log_sink: ->(chunk) { log("[summarizer] #{chunk}") }
    ).call
  rescue StandardError => e
    log("[summarizer] failed: #{e.class}: #{e.message} — falling back to template")
    PrSummarizer::Result.new(title: nil, body: nil, error: "#{e.class}: #{e.message}")
  end

  def pr_summarizer_context
    @job.cron? ? @job.synthetic_issue : GithubClient.for(@job.user).fetch_issue(@job.repository.slug, @job.issue_number)
  end

  # Cron PRs don't close any issue (no `Closes #N`). The body still
  # carries the LLM-disclosure footer.
  def compose_body(agent_body)
    parts = []
    parts << "Closes ##{@job.issue_number}" if @job.issue?
    parts << "" if @job.issue?
    parts << agent_body
    parts << ""
    parts << "---"
    parts << "*Authored by an LLM (Run took #{@run.agent_turns || '?'} turn(s), trigger=#{@run.trigger_kind}). Review carefully.*"
    parts.join("\n")
  end

  def template_title
    if @job.cron?
      "[syrus] scheduled: #{@job.scheduled_task&.name || "task ##{@job.scheduled_task_id}"}"
    else
      "[syrus] #{@job.repository.slug}##{@job.issue_number}"
    end
  end

  def template_body
    if @job.cron?
      task_name = @job.scheduled_task&.name || "##{@job.scheduled_task_id}"
      "Opened by a Syrus scheduled task (`#{task_name}`). Run took #{@run.agent_turns || '?'} turn(s).\n\nReview the diff carefully — this PR was authored by an LLM."
    else
      "Closes ##{@job.issue_number}\n\nOpened by Syrus from issue ##{@job.issue_number}. Run took #{@run.agent_turns || '?'} turn(s) (#{@run.trigger_kind}).\n\nReview the diff carefully — this PR was authored by an LLM."
    end
  end

  def log(chunk)
    next_seq = (@run.job_logs.maximum(:sequence) || -1) + 1
    @run.job_logs.create!(chunk: chunk, sequence: next_seq)
    @run.update_column(:last_heartbeat_at, Time.current) if @run.running?
  end
end
