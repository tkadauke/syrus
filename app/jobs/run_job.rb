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

    if @run.rebase?
      rebase_and_force_push
    else
      run_agent_and_commit
      abort_if_cancelled!

      push_branch
      abort_if_cancelled!

      open_pull_request_if_missing
    end

    schedule_mergeability_recheck

    @run.succeed!
    @run.save!
    log(complete_message)
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
    prompt = @run.prompt.presence || compose_initial_prompt
    @run.update!(prompt: prompt) if @run.prompt.blank?

    log("invoking agent for #{@job.repository.slug}##{@job.issue_number} (run #{@run.id}, trigger=#{@run.trigger_kind})")

    result = with_mcp_config do |mcp_config_path|
      AgentInvocation.new(
        @workspace.path,
        prompt: prompt,
        oauth_token: @job.user.claude_oauth_token,
        log_sink: ->(chunk) { log(chunk) },
        runner: self.class.agent_runner,
        mcp_config: mcp_config_path
      ).run
    end

    persist_agent_metadata(result)

    raise AgentRunFailed, "agent timed out" if result.timed_out
    raise AgentRunFailed, "agent reported #{result.outcome || 'error'}" if result.is_error
    raise AgentRunFailed, "agent exited #{result.exit_status}" unless result.success?

    commit_agent_changes
    diff = capture_diff_against_default

    raise AgentRunFailed, "agent produced no changes" if diff.blank?

    @run.update!(agent_diff: diff, head_sha: head_sha)
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
        mcp_config: mcp_config_path
      ).run
    end

    persist_agent_metadata(result)

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
    elsif @run.initial?
      "run complete — PR ##{@job.pr_number} opened"
    else
      "run complete — follow-up commit pushed"
    end
  end

  # Initial runs get the issue title + body via Prompts::Initial.
  # Follow-up runs (pr_comment, ci_failure, ...) arrive with @run.prompt
  # already composed by whatever job created them — we use it as-is.
  def compose_initial_prompt
    issue = GithubClient.for(@job.user).fetch_issue(@job.repository.slug, @job.issue_number)
    Prompts::Initial.new(issue: issue).to_s
  end

  def persist_agent_metadata(result)
    updates = {}
    updates[:agent_turns] = result.turns if result.turns
    updates[:agent_outcome] = result.outcome if result.outcome
    @run.update!(updates) if updates.any?
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
    if @run.initial?
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

  # Asks claude to author a clean PR title + body from the issue + the
  # diff we just produced. Returns a PrSummarizer::Result. We never let
  # this fail the Run: any error path falls back to the templated title
  # and body.
  def summarize_for_pr
    issue = GithubClient.for(@job.user).fetch_issue(@job.repository.slug, @job.issue_number)
    log("[summarizer] composing PR title and body…")
    PrSummarizer.new(
      issue: issue,
      diff: @run.agent_diff,
      oauth_token: @job.user.claude_oauth_token,
      log_sink: ->(chunk) { log("[summarizer] #{chunk}") }
    ).call
  rescue StandardError => e
    log("[summarizer] failed: #{e.class}: #{e.message} — falling back to template")
    PrSummarizer::Result.new(title: nil, body: nil, error: "#{e.class}: #{e.message}")
  end

  def compose_body(agent_body)
    [
      "Closes ##{@job.issue_number}",
      "",
      agent_body,
      "",
      "---",
      "*Authored by an LLM (Run took #{@run.agent_turns || '?'} turn(s), trigger=#{@run.trigger_kind}). Review carefully.*"
    ].join("\n")
  end

  def template_title
    "[syrus] #{@job.repository.slug}##{@job.issue_number}"
  end

  def template_body
    "Closes ##{@job.issue_number}\n\nOpened by Syrus from issue ##{@job.issue_number}. Run took #{@run.agent_turns || '?'} turn(s) (#{@run.trigger_kind}).\n\nReview the diff carefully — this PR was authored by an LLM."
  end

  def log(chunk)
    next_seq = (@run.job_logs.maximum(:sequence) || -1) + 1
    @run.job_logs.create!(chunk: chunk, sequence: next_seq)
    @run.update_column(:last_heartbeat_at, Time.current) if @run.running?
  end
end
