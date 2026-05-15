module Steps
  # First step in Initial / Retry / PrFeedback / CiFailure
  # workflows. Runs deterministic setup work in the workspace
  # BEFORE handing off to the agent — package-manager installs
  # mostly (`bundle install`, `npm ci`, etc.) so the agent doesn't
  # burn turns/tokens watching dependencies download.
  #
  # Source of commands: RepoPrepPlan reads `.syrus.yml` from the
  # repo root, falls back to auto-detect on common lockfile
  # signals. Empty plan = step succeeds with a one-line "nothing
  # to do" message — chain shape stays uniform across workflows
  # whether or not the repo opts in.
  #
  # Per-command timeout caps a hung install so the workflow can
  # fail loudly instead of pegging the worker thread until the
  # reaper trips.
  class Prepare < Base
    PER_COMMAND_TIMEOUT = 10.minutes.to_i

    # Mirror of AgentInvocation::AGENT_ENV_FORWARD. Prep commands
    # run with EXACTLY this env (unsetenv_others: true) so the
    # worker pod's BUNDLE_PATH=/usr/local/bundle, BUNDLE_DEPLOYMENT=1,
    # BUNDLE_WITHOUT="development:test", RAILS_ENV=production, etc.
    # don't leak into a `bundle install` that's supposed to install
    # the target repo's gems (incl. test gems) into the workspace.
    # Same posture the agent gets — predictable, repo-independent.
    PREP_ENV_FORWARD = %w[
      HOME USER LOGNAME PATH TERM LANG LC_ALL LC_CTYPE TZ HOSTNAME TMPDIR SHELL
      MISE_DATA_DIR
    ].freeze

    def call
      workspace.setup
      plan = RepoPrepPlan.for(workspace.path)

      log("[prepare] source: #{plan.source}")
      log("[prepare] note: #{plan.note}") if plan.note

      if plan.commands.empty?
        log("[prepare] no commands to run; skipping")
        return
      end

      plan.commands.each_with_index do |cmd, i|
        log("[prepare] (#{i + 1}/#{plan.commands.size}) $ #{cmd}")
        run_shell(cmd)
      end

      log("[prepare] all commands completed successfully")
    end

    private

    # `bash -c` so quoting / pipelines / && in commands work.
    # cwd = workspace path. Env scrubbed via PREP_ENV_FORWARD +
    # unsetenv_others. Streams stdout+stderr (popen2e merges them)
    # into JobLog one line at a time so the operator can watch the
    # install live. Hard timeout via a watcher thread that SIGTERMs
    # the process tree if it exceeds the budget.
    def run_shell(cmd)
      buffer = new_log_buffer
      result = ProcessRunner.new(
        env: env,
        command: [ "bash", "-c", cmd ],
        chdir: workspace.path,
        timeout: PER_COMMAND_TIMEOUT,
        on_output_chunk: ->(chunk) { stream_buffered_chunk(buffer, chunk) }
      ).run
      flush_log_buffer(buffer)

      if result.timed_out
        raise StepFailed, "prepare command timed out after #{PER_COMMAND_TIMEOUT}s: #{cmd}"
      elsif !result.success?
        raise StepFailed, "prepare command failed (exit #{result.exit_status}): #{cmd}"
      end
    end

    # Read `io` until EOF, batching writes into JobLog. Flush becomes due
    # when the buffer crosses LOG_FLUSH_BYTES or LOG_FLUSH_INTERVAL elapses,
    # but is rate-limited by LOG_FLUSH_MIN_GAP unless LOG_FLUSH_MAX_BUF is
    # reached. The IO.select timeout shrinks toward the next eligible flush
    # deadline, so quiet streams still flush promptly.
    def stream_buffered(io)
      buffer = new_log_buffer
      loop do
        timeout = next_log_flush_timeout(buffer[:content], buffer[:last_flush])
        ready, = IO.select([ io ], nil, nil, timeout)

        unless ready
          flush_log_buffer(buffer) if log_flush_ready?(buffer[:content], buffer[:last_flush])
          next
        end

        begin
          stream_buffered_chunk(buffer, io.read_nonblock(16 * 1024))
        rescue IO::WaitReadable
          next
        rescue EOFError
          break
        end
      end
    ensure
      flush_log_buffer(buffer) if buffer
    end

    def new_log_buffer
      { content: +"", last_flush: Time.current }
    end

    def stream_buffered_chunk(buffer, chunk)
      buffer[:content] << chunk
      flush_log_buffer(buffer) if log_flush_ready?(buffer[:content], buffer[:last_flush])
    end

    def flush_log_buffer(buffer)
      return if buffer[:content].empty?

      log(buffer[:content].chomp, kind: "system")
      buffer[:content].clear
      buffer[:last_flush] = Time.current
    end

    def next_log_flush_timeout(buffer, last_flush)
      elapsed = Time.current - last_flush
      deadlines = [ LOG_FLUSH_INTERVAL ]
      deadlines << LOG_FLUSH_MIN_GAP if buffer.bytesize >= LOG_FLUSH_BYTES
      timeout = deadlines.min - elapsed
      timeout.positive? ? timeout : 0
    end

    def env
      ProcessRunner.forwarded_env(PREP_ENV_FORWARD)
    end
  end
end
