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
  #   and cross-step resume threading.
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

    # Shared transcript-append + heartbeat-bump for this Run, used
    # by streamed agent output and by handler-emitted log lines.
    # Resilient to blank input — see RunJob#log for the same
    # contract; RecordInvalid on empty chunks would crash a step
    # mid-stream.
    def log(chunk, kind: nil)
      text = chunk.to_s
      if text.strip.empty?
        run.update_column(:last_heartbeat_at, Time.current) if run.running?
        return
      end
      next_seq = (run.job_logs.maximum(:sequence) || -1) + 1
      run.job_logs.create!(chunk: text, sequence: next_seq, kind: kind)
      run.update_column(:last_heartbeat_at, Time.current) if run.running?
    end

    # Returns [sink, flush] — a buffering wrapper around #log. The sink
    # lambda accumulates chunks and flushes to one JobLog row when either
    # LOG_FLUSH_BYTES or LOG_FLUSH_INTERVAL elapses. Flush also triggers
    # on kind change so different-typed chunks stay in separate rows.
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

      sink = lambda do |chunk, kind: nil|
        text = chunk.to_s
        next if text.strip.empty?  # mirrors #log: blank lines don't accumulate
        flush.call if !buffer.empty? && kind != last_kind
        last_kind = kind
        buffer << text
        elapsed = Time.current - last_flush
        flush.call if buffer.bytesize >= LOG_FLUSH_BYTES || elapsed >= LOG_FLUSH_INTERVAL
      end

      [ sink, flush ]
    end

    # ---- Agentic helpers (used by agent-spawning handlers) ----

    # Drive the configured agent provider in this Workflow's workspace,
    # threading `--resume` from the upstream step's session when
    # one is available. Streams transcript chunks into JobLog,
    # captures the new session transcript on success, raises StepFailed
    # on any of the non-success outcomes.
    def run_agent(prompt:, max_turns: nil)
      sink, flush = buffered_log_sink
      begin
        result = agent_adapter.run(prompt: prompt, log_sink: sink, max_turns: max_turns)
      ensure
        flush.call
      end

      persist_agent_metadata(result)
      capture_agent_session(result)

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

    # Resume threading. v1 contract: `--resume` only crosses Step
    # boundaries *within the same Workflow*. Cross-Workflow chains
    # (Initial → PrFeedback) start a fresh session — the
    # downstream prompt carries enough context (issue body +
    # comment + diff) without dragging hours-old conversation in.
    def parent_session_id
      run.parent_session_id.presence || step.upstream_session_id
    end

    # Capture the agent session JSONL into ClaudeSession. The table/model
    # name is still historical; provider marks which CLI produced it.
    def capture_agent_session(result)
      capture = agent_adapter.session_capture(result)
      return unless capture

      if capture.transcript_jsonl.blank?
        log(capture.missing_message) if capture.missing_message.present?
        log("[agent_session] no transcript captured for #{capture.provider} session #{capture.session_id}")
        return
      end

      ClaudeSession.create!(
        run: run,
        provider: capture.provider,
        session_id: capture.session_id,
        transcript_jsonl: capture.transcript_jsonl
      )
      log("[agent_session] captured #{capture.provider} #{capture.session_id} (#{capture.transcript_jsonl.bytesize} bytes)")
    rescue StandardError => e
      log("[agent_session] capture failed: #{e.class}: #{e.message}")
    end

    def persist_agent_metadata(result)
      updates = {}
      updates[:agent_turns] = result.turns if result.turns
      updates[:agent_outcome] = result.outcome if result.outcome
      run.update!(updates) if updates.any?
    end

    # ---- Workspace + git helpers ----

    # `git diff <default>...HEAD` for what THIS branch contributed
    # since it diverged from default. Three-dot — what GitHub's
    # "Files changed" tab shows.
    def diff_against_default
      streaming_git.run("diff", "#{repository.default_branch}...HEAD",
                       chdir: workspace.path.to_s)
    end

    def head_sha
      GitRunner.new.run("rev-parse", "HEAD", chdir: workspace.path.to_s).strip
    end

    def streaming_git(env: {})
      GitRunner.new(log_sink: ->(line) { log(line.chomp, kind: "system") }, env: env)
    end

    # Defensive check: the agent didn't run a `git checkout
    # --orphan` or equivalent that severs HEAD's history from
    # default branch. Same outcome label as RunJob's existing
    # check (`git_state_corrupt`) so the dashboard can tell this
    # class of failure apart from generic AgentRunFailed.
    class AgentBrokeGitState < StepFailed; end

    def assert_branch_history_intact!
      base = repository.default_branch
      streaming_git.run("merge-base", base, "HEAD", chdir: workspace.path.to_s)
    rescue GitRunner::GitError
      run.update!(agent_outcome: "git_state_corrupt")
      raise AgentBrokeGitState,
            "agent's branch has no common ancestor with #{base} — orphan/detached state. " \
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
