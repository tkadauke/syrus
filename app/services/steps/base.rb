module Steps
  # Base class for all v1 step handlers. A handler is a PORO that
  # takes a Run, does the work for one Step's one attempt, and
  # returns. Handlers do *not* manage Run/Step state transitions —
  # the orchestrator (RunJob's dispatch) wraps the call and
  # transitions on success / fail.
  #
  # Two flavors:
  #
  # - **Agentic handlers** (Implement, Summarize, Respond,
  #   SummarizeAmend, AnalyzeAndFix, AgentRebase, Manual) spawn
  #   the Workflow's configured agent provider. They share the helpers
  #   in this base class for prompt resolution, generic session capture,
  #   and cross-step session continuation.
  #
  # - **Non-agentic handlers** (PrOpen, Push, AutoRebase,
  #   ForcePush) just run service code (PullRequestOpener,
  #   `git push`, AutoRebase service). They use the same
  #   workspace and #log API as agentic handlers but don't touch
  #   any of the agent/MCP/session machinery.
  #
  # Handlers raise StepFailed on irrecoverable failure. The
  # orchestrator catches it, transitions the Run + Step to
  # failed, and increments the Workflow's failure_count.
  class Base
    class StepFailed < StandardError; end

    # Shared buffering thresholds — used by buffered_log_sink (agent
    # output) and by Prepare#stream_buffered (shell command output).
    LOG_FLUSH_BYTES    = 16 * 1024
    LOG_FLUSH_INTERVAL = 1.0
    LOG_FLUSH_MIN_GAP  = 0.2
    LOG_FLUSH_MAX_BUF  = 1.megabyte

    attr_reader :run, :step, :workflow, :job, :repository

    def initialize(run)
      @run = run
      @step = run.step
      @workflow = step.workflow
      @job = workflow.job
      @repository = job.repository
    end

    def call
      raise NotImplementedError, "#{self.class.name} must implement #call"
    end

    private

    def workspace
      @workspace ||= WorkflowWorkspace.new(workflow)
    end

    def workspace_dependency_env
      WorkspaceDependencyEnv.for(workspace.path)
    end

    # Shared transcript-append + heartbeat-bump for this Run, used
    # by streamed agent output and by handler-emitted log lines.
    # Resilient to blank input — see RunJob#log for the same
    # contract; RecordInvalid on empty chunks would crash a step
    # mid-stream.
    def log(chunk, kind: nil, **)
      text = chunk.to_s
      if text.strip.empty?
        run.update_column(:last_heartbeat_at, Time.current) if run.running?
        return
      end
      JobLog.append!(run: run, chunk: text, kind: kind)
      run.update_column(:last_heartbeat_at, Time.current) if run.running?
    end

    # Returns [sink, flush] — a buffering wrapper around #log. The sink
    # lambda accumulates chunks and flushes to one JobLog row when either
    # LOG_FLUSH_BYTES or LOG_FLUSH_INTERVAL elapses, but never more often
    # than LOG_FLUSH_MIN_GAP unless LOG_FLUSH_MAX_BUF is reached. Flush also
    # triggers on kind change so different-typed chunks stay in separate rows.
    # Caller must call flush.call after the stream ends to drain any
    # trailing partial buffer.
    def buffered_log_sink
      buffer     = +""
      last_kind  = nil
      last_flush = Time.current

      flush = lambda do
        next if buffer.empty?
        log(buffer.chomp, kind: last_kind)
        buffer.clear
        last_flush = Time.current
      end

      # `**` swallows the structured kwargs that ClaudeInvocation /
      # CodexInvocation pass on tool_use / tool_result events
      # (tool_name, tool_input, tool_result_content, tool_use_id,
      # …). The buffered sink only uses chunk + kind for log
      # batching; the structured metadata is consumed by callers
      # that wire log_sink directly (e.g. ChatTurnJob). Without the
      # `**`, every submit_summary call (and any other MCP tool
      # use) blows up with ArgumentError mid-run. Mirrors the
      # `**` in RunJob#log and Steps::Base#log for the same reason.
      sink = lambda do |chunk, kind: nil, **|
        text = chunk.to_s
        next if text.strip.empty?  # mirrors #log: blank lines don't accumulate
        flush.call if !buffer.empty? && kind != last_kind
        last_kind = kind
        buffer << text
        flush.call if log_flush_ready?(buffer, last_flush)
      end

      [ sink, flush ]
    end

    def log_flush_ready?(buffer, last_flush)
      elapsed = Time.current - last_flush
      flush_due = buffer.bytesize >= LOG_FLUSH_BYTES || elapsed >= LOG_FLUSH_INTERVAL
      rate_ok = elapsed >= LOG_FLUSH_MIN_GAP || buffer.bytesize >= LOG_FLUSH_MAX_BUF

      flush_due && rate_ok
    end

    def utf8(text)
      string = text.to_s
      if string.encoding == Encoding::ASCII_8BIT
        string.dup.force_encoding(Encoding::UTF_8).scrub("")
      else
        string.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "")
      end
    end

    # ---- Agentic helpers (used by agent-spawning handlers) ----

    # Drive the configured agent provider in this Workflow's workspace,
    # continuing from the upstream step's session when
    # one is available. Streams transcript chunks into JobLog,
    # captures the new session transcript on success, raises StepFailed
    # on any of the non-success outcomes.
    def run_agent(prompt:, max_turns: nil)
      prompt = AgentEnvironmentSnapshot.new(run: run, workspace_path: workspace.path).apply_to(prompt)
      prompt = JobAttachmentContext.new(job: job, workspace_path: workspace.path).apply_to(prompt)
      sink, flush = buffered_log_sink
      begin
        result = agent_adapter.run(prompt: prompt, log_sink: sink, max_turns: max_turns)
      ensure
        flush.call
      end

      agent_adapter.record_result!(result, log: ->(message) { log(message) })

      raise StepFailed, "agent timed out"                            if result.timed_out
      raise StepFailed, "agent reported #{result.outcome || 'error'}" if result.is_error
      raise StepFailed, "agent exited #{result.exit_status}"          unless result.success?

      result
    rescue AgentProviders::ConfigurationError => e
      raise StepFailed, e.message
    end

    def agent_provider
      run.agent_provider.presence || workflow.agent_provider.presence || job.user.agent_provider
    end

    def agent_adapter
      @agent_adapter ||= AgentProviders.for(agent_provider).new(
        run: run,
        workspace: workspace,
        parent_session_id: parent_session_id
      )
    end

    # Session continuation. v1 contract: `--resume` only crosses Step
    # boundaries *within the same Workflow*. Cross-Workflow chains
    # (Initial → PrFeedback) start a fresh session — the
    # downstream prompt carries enough context (issue body +
    # comment + diff) without dragging hours-old conversation in.
    def parent_session_id
      run.parent_session_id.presence || step.upstream_session_id
    end

    # ---- Workspace + git helpers ----

    # `git diff origin/<default>...HEAD` for what THIS branch
    # contributed since it diverged from default. Three-dot — what
    # GitHub's "Files changed" tab shows.
    #
    # Uses a non-streaming GitRunner: the diff is captured as the
    # return value (stored on Run#agent_diff and rendered on the Job
    # page's dedicated diff panel). Streaming the output through the
    # log_sink would also dump the entire diff into the transcript,
    # which (a) bloats JobLog rows on large changes and (b) duplicates
    # data that already lives in Run#agent_diff. Mirror the same
    # capture-only pattern head_sha uses below.
    def diff_against_default
      GitRunner.new.run("diff", "#{default_branch_ref}...HEAD",
                       chdir: workspace.path.to_s)
    end

    def default_branch_ref
      "origin/#{repository.default_branch}"
    end

    def head_sha
      GitRunner.new.run("rev-parse", "HEAD", chdir: workspace.path.to_s).strip
    end

    def streaming_git(env: {})
      GitRunner.new(log_sink: ->(line) { log(line.chomp, kind: "system") }, env: env)
    end

    # Shared lifecycle for agentic steps that are expected to change
    # the repository: prepare the workspace, compose/persist any prompt
    # state supplied by the concrete step, invoke the agent, commit its
    # edits, verify git history, and capture the GitHub-style diff.
    def perform_agentic_change_step(log_message:, commit_message:)
      workspace.setup
      yield if block_given?

      log(log_message)
      run_agent(prompt: run.prompt)

      commit_agent_changes(commit_message)
      assert_branch_history_intact!

      diff = diff_against_default
      raise StepFailed, "agent produced no changes" if diff.blank?

      run.update!(agent_diff: diff, head_sha: head_sha)
    end

    # Agent edits files; we commit them locally with a placeholder
    # message. Downstream summarize steps rewrite the final commit
    # message before push/open.
    def commit_agent_changes(commit_message)
      chdir = workspace.path.to_s
      git = streaming_git
      status = git.run("status", "--porcelain", chdir: chdir)
      return if status.strip.empty?

      git.run("add", "-A", chdir: chdir)
      git.run("commit", "-m", commit_message, chdir: chdir)
    end

    # Defensive check: the agent didn't run a `git checkout
    # --orphan` or equivalent that severs HEAD's history from
    # default branch. Same outcome label as RunJob's existing
    # check (`git_state_corrupt`) so the dashboard can tell this
    # class of failure apart from generic AgentRunFailed.
    class AgentBrokeGitState < StepFailed; end

    def assert_branch_history_intact!
      # Use the remote-tracking ref (`origin/<default>`), not the bare
      # local branch name. WorkflowWorkspace clones with
      # `--branch <effective_base_branch>` — which for stacked-PR Jobs
      # is the parent stack branch, not master. In that case the local
      # repo has no `master` ref at all and a bare `git merge-base
      # master HEAD` exits 128 ("Not a valid object name"), false-
      # positively flagging perfectly normal agent work as corrupt
      # git state. `refs/remotes/origin/<default>` is always present
      # after clone regardless of which branch was checked out.
      base_ref = default_branch_ref
      # Non-streaming: we only care about success-or-raise here. The
      # merge-base SHA (the only output of this command) isn't useful
      # in the transcript and just adds noise above the agent_diff.
      GitRunner.new.run("merge-base", base_ref, "HEAD", chdir: workspace.path.to_s)
    rescue GitRunner::GitError
      run.update!(agent_outcome: "git_state_corrupt")
      raise AgentBrokeGitState,
            "agent's branch has no common ancestor with #{base_ref} — orphan/detached state. " \
            "Likely cause: agent ran `git checkout --orphan`, `git reset --hard <unrelated>`, or similar."
    end

    # ---- Chain control ----

    # Cancel every downstream step in the linear chain. Used by
    # steps that have determined their successors have nothing to
    # do (e.g. AutoRebase that succeeded cleanly leaves
    # AgentRebase + ForcePush with no work). The dispatcher
    # walks past cancelled steps when advancing, so cancelling
    # downstream is the way to make a chain terminate early
    # without hacky artifact flags.
    #
    # Idempotent — already-terminal steps are left alone. Walks
    # the linear chain via next_step pointer; a v3 graph would
    # need a graph-traversal version of this.
    def cancel_downstream!(reason: nil)
      Step.suppress_cancel_cascade do
        cursor = step.next_step
        while cursor
          if cursor.may_cancel?
            log("[#{step.kind}] cancelling downstream step ##{cursor.id} (#{cursor.kind})#{reason ? ': ' + reason : ''}")
            cursor.cancel!
            cursor.save!
          end
          cursor = cursor.next_step
        end
      end
    end
  end
end
