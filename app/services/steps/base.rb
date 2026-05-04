require "tempfile"

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
  #   claude via AgentInvocation. They share the helpers in this
  #   base class for prompt resolution, MCP config, session
  #   capture, and cross-step `--resume` threading.
  #
  # - **Non-agentic handlers** (PrOpen, Push, AutoRebase,
  #   ForcePush) just run service code (PullRequestOpener,
  #   `git push`, AutoRebase service). They use the same
  #   workspace and #log API as agentic handlers but don't touch
  #   any of the claude/MCP/session machinery.
  #
  # Handlers raise StepFailed on irrecoverable failure. The
  # orchestrator catches it, transitions the Run + Step to
  # failed, and increments the Workflow's failure_count.
  class Base
    class StepFailed < StandardError; end

    # Shared buffering thresholds — used by buffered_log_sink (claude
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

    # ---- Agentic helpers (used by claude-spawning handlers) ----

    # Drive an AgentInvocation in this Workflow's workspace,
    # threading `--resume` from the upstream step's session when
    # one is available. Streams transcript chunks into JobLog,
    # captures the new session JSONL on success, raises StepFailed
    # on any of the non-success outcomes.
    def run_agent(prompt:, max_turns: nil)
      with_mcp_config do |mcp_config_path|
        sink, flush = buffered_log_sink
        begin
          result = AgentInvocation.new(
            workspace.path,
            prompt: prompt,
            oauth_token: job.user.claude_oauth_token,
            log_sink: sink,
            runner: RunJob.agent_runner,
            max_turns: max_turns || job.user.agent_max_turns,
            mcp_config: mcp_config_path,
            resume_session_id: parent_session_id
          ).run
        ensure
          flush.call
        end

        persist_agent_metadata(result)
        capture_claude_session(result)

        raise StepFailed, "agent timed out"                                 if result.timed_out
        raise StepFailed, "agent reported #{result.outcome || 'error'}"      if result.is_error
        raise StepFailed, "agent exited #{result.exit_status}"               unless result.success?

        result
      end
    end

    # Per-Run mcp.json tempfile so claude knows how to reach our
    # sidecar. `alwaysLoad: true` (claude-code v2.1.121+) skips
    # tool-search deferral and keeps `mcp__syrus__submit_summary`
    # in the agent's active tool list at all times — including on
    # `--resume`d sessions, where claude was otherwise routing MCP
    # tools through the deferred catalog and the resumed agent
    # couldn't find them. (Smoking gun: Run #181's transcript,
    # where the summarize agent's first action was a ToolSearch
    # for `AskUserQuestion` because submit_summary wasn't visible.)
    # Server key MUST match the binary basename (`syrus-mcp-sidecar`).
    # claude-code derives the MCP-tool prefix differently between
    # fresh and `--resume`d invocations: fresh uses the config
    # key, resume uses the binary basename. If those differ, the
    # resumed agent invokes a tool name that doesn't exist —
    # exactly Run 206's failure: implement saw the tool as
    # `mcp__syrus__submit_summary` (config key "syrus"), summarize
    # tried to call `mcp__syrus-mcp-sidecar__submit_summary`
    # (binary basename) and got "no such tool available." Aligning
    # the names sidesteps the underlying claude-code quirk;
    # SyrusMcp::Sidecar also reports the same name via serverInfo
    # so all three sources agree.
    def with_mcp_config
      Tempfile.create([ "syrus-mcp-#{run.id}-", ".json" ]) do |f|
        f.write({
          mcpServers: {
            "syrus-mcp-sidecar" => {
              type: "stdio",
              command: Rails.root.join("bin/syrus-mcp-sidecar").to_s,
              args: [ "--run-id", run.id.to_s ],
              # Forward the worker's Bundler env to the sidecar.
              # AgentInvocation strips Bundler vars before launching
              # claude (so the agent doesn't accidentally use
              # Syrus's bundle when working in the target repo);
              # claude in turn doesn't restore them when spawning
              # MCP server children. Without these forwarded back,
              # the sidecar's Rails boot can't find Syrus's gems
              # (BUNDLE_PATH points to /usr/local/bundle in the
              # prod image; nil in dev where the default works).
              # The binstub force-sets BUNDLE_GEMFILE itself; we
              # supply BUNDLE_PATH and friends here so deployment
              # / without rules carry over.
              env: sidecar_env,
              alwaysLoad: true
            }
          }
        }.to_json)
        f.flush
        yield f.path
      end
    end

    # Env vars the sidecar needs to boot Syrus's Rails app and reach
    # MySQL. claude is launched with `unsetenv_others: true` and a
    # narrow allowlist (so the agent's claude doesn't accidentally
    # see Syrus-internal credentials or use Syrus's bundle); claude
    # then doesn't put any of those back when spawning MCP server
    # children. Without this forwarding, the sidecar inherits a
    # near-empty env, Rails defaults to `development` (which loads
    # gems not installed in the prod-WITHOUT bundle), and the boot
    # crashes before claude completes the MCP handshake — hence
    # `mcp_servers: [{name: syrus-mcp-sidecar, status: failed}]`.
    SIDECAR_ENV_FORWARD = %w[
      RAILS_ENV
      RAILS_MASTER_KEY
      SECRET_KEY_BASE
      RAILS_LOG_TO_STDOUT
      DB_HOST
      SYRUS_DATABASE_PASSWORD
      BUNDLE_PATH
      BUNDLE_DEPLOYMENT
      BUNDLE_WITHOUT
      TZ
    ].freeze

    def sidecar_env
      ENV.slice(*SIDECAR_ENV_FORWARD).compact
    end

    # Resume threading. v1 contract: `--resume` only crosses Step
    # boundaries *within the same Workflow*. Cross-Workflow chains
    # (Initial → PrFeedback) start a fresh session — the
    # downstream prompt carries enough context (issue body +
    # comment + diff) without dragging hours-old conversation in.
    def parent_session_id
      run.parent_session_id.presence || step.upstream_session_id
    end

    # Capture the claude session JSONL from disk into ClaudeSession
    # for cross-pod survival (Resume Run / cross-Workflow Resume).
    # Best-effort — skip if claude didn't emit a session_id, skip
    # if the JSONL isn't where we expected. Same logic + error
    # handling as RunJob#persist_claude_session.
    def capture_claude_session(result)
      return unless result.session_id
      path = ClaudeSession.canonical_path_for(
        home: ENV.fetch("HOME"),
        cwd: workspace.path,
        session_id: result.session_id
      )
      unless File.exist?(path)
        log("[claude_session] no JSONL at #{path} — Resume won't be available for this Run")
        return
      end
      ClaudeSession.create!(run: run, session_id: result.session_id, transcript_jsonl: File.read(path))
      log("[claude_session] captured #{result.session_id} (#{File.size(path)} bytes)")
    rescue StandardError => e
      log("[claude_session] capture failed: #{e.class}: #{e.message}")
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
