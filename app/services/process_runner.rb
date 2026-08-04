require "open3"
require "socket"

# Small shared wrapper for subprocess lifetime management. Callers still own
# command construction and output parsing; this class owns the boring parts:
# scrubbed env, process-group spawning, timeout/stop handling, streaming,
# SpawnedProcess registration + heartbeats + the operator kill switch, and
# a common result shape.
class ProcessRunner
  Result = Data.define(
    :exit_status, :timed_out, :stopped, :silent_timed_out, :operator_killed,
    :aliveness_failed, :duration_s, :spawned_process_id
  ) do
    def success?
      !timed_out && !stopped && !silent_timed_out && !operator_killed && !aliveness_failed && exit_status == 0
    end
    def timed_out? = timed_out
    def stopped? = stopped
    def silent_timed_out? = silent_timed_out
    def operator_killed? = operator_killed
    def aliveness_failed? = aliveness_failed
  end

  TERM_GRACE_SECONDS = 5
  READ_CHUNK_BYTES = 16 * 1024
  KILL_POLL_INTERVAL_SECONDS = 1
  HEARTBEAT_INTERVAL_SECONDS = 15

  def self.forwarded_env(keys, extra: {})
    ENV.slice(*keys).merge(extra.compact)
  end

  # `kind:` is the SpawnedProcess kind (one of SpawnedProcess::KINDS) —
  # production callers always pass this so the spawned-process admin
  # surface sees them. Test callers can omit it; nil means we skip
  # registration.
  #
  # `silent_timeout` (seconds, or nil to disable): kill the subprocess
  # if it produces no output for this long. The wall-clock `timeout`
  # is a separate ceiling — the silent timeout fires faster for the
  # common "agent process wedged" failure mode (today's incident: a
  # codex CLI stopped emitting output and the worker thread blocked
  # on the IO.select read for 50+ minutes, holding its SolidQueue
  # claim + concurrency semaphore for the rest of the worker's life).
  #
  # Don't set silent_timeout for inherently bursty commands like
  # `bundle install` or `git clone` — those have natural silent
  # phases longer than any sensible threshold. Reserve for streaming
  # agent invocations where continuous output is the norm.
  def initialize(env:, command:, chdir:, timeout:, stdin_data: nil,
                 unsetenv_others: true, pgroup: true,
                 stop_requested: -> { false },
                 on_output_chunk: nil,
                 on_output_line: nil,
                 kill_grace_seconds: TERM_GRACE_SECONDS,
                 silent_timeout: nil,
                 kind: nil,
                 run: nil,
                 workflow: nil,
                 display_command: nil,
                 on_spawned_process: nil)
    @env = env
    @command = command
    @chdir = chdir.to_s
    @timeout = timeout
    @stdin_data = stdin_data
    @unsetenv_others = unsetenv_others
    @pgroup = pgroup
    @stop_requested = stop_requested
    @on_output_chunk = on_output_chunk
    @on_output_line = on_output_line
    @kill_grace_seconds = kill_grace_seconds
    @silent_timeout = silent_timeout
    @kind = kind
    @run = run
    @workflow = workflow
    @display_command = display_command
    @on_spawned_process = on_spawned_process

    # Idempotent — only the first call in this process spawns the
    # supervisor thread. Web pods never reach this code path so they
    # never get a supervisor thread (nothing to supervise there).
    SpawnedProcessSupervisor.ensure_running if @kind
  end

  def run
    timed_out = false
    stopped = false
    silent_timed_out = false
    operator_killed = false
    aliveness_failed = false
    result = nil
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    @spawned_process = register_spawned_process
    @on_spawned_process&.call(@spawned_process) if @spawned_process

    begin
      Open3.popen2e(@env, *@command,
                    chdir: @chdir,
                    unsetenv_others: @unsetenv_others,
                    pgroup: @pgroup) do |stdin, output, wait_thread|
        update_pid!(wait_thread.pid)
        write_stdin(stdin)

        killer = Thread.new do
          sleep @timeout
          timed_out = true
          terminate(wait_thread.pid)
        end

        last_kill_check = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        # Tracks the first time we observed the pid missing. The
        # aliveness probe only fires if ESRCH persists past
        # ALIVENESS_GRACE — that races otherwise with the wait_thread's
        # async exit-status update, killing every fast-exiting clean
        # subprocess (e.g. `git --version` finishing before Ruby's
        # wait_thread thread notices it exited).
        aliveness_grace = 1.0
        first_esrch_at = nil

        silent_check = ->(last_chunk_at) {
          # If wait_thread is done, the process exited normally — let
          # the main loop break out cleanly.
          return false if wait_thread.respond_to?(:join) && wait_thread.join(0)

          begin
            Process.kill(0, wait_thread.pid)
            first_esrch_at = nil
          rescue Errno::ESRCH
            # Pid is gone. If wait_thread had also reported done, the
            # branch above would have returned false. Wait the grace
            # window for wait_thread to catch up; if it still hasn't,
            # treat as the genuine "parent dead, pipe held by child"
            # case and terminate.
            first_esrch_at ||= Process.clock_gettime(Process::CLOCK_MONOTONIC)
            elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - first_esrch_at
            return :aliveness if elapsed >= aliveness_grace
          rescue Errno::EPERM
            # Can't signal — pid exists. Fall through to silence check.
            first_esrch_at = nil
          end

          # Silence-based check. Only fires if a silent_timeout was
          # configured; default behavior is unlimited silence
          # (relying on the wall-clock timeout to backstop).
          return false unless @silent_timeout
          return false unless last_chunk_at
          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - last_chunk_at
          elapsed >= @silent_timeout ? :silent : false
        }

        kill_poll = ->(now) {
          # Cross-pod kill via DB: the operator's Kill button stamps
          # SpawnedProcess#kill_requested_at; we poll for it once a
          # second from the loop. Avoids hammering the DB on every
          # 100ms iteration.
          return false unless @spawned_process
          return false if now - last_kill_check < KILL_POLL_INTERVAL_SECONDS

          last_kill_check = now
          @spawned_process.reload
          @spawned_process.kill_requested?
        }

        stream_output(output, wait_thread, silent_check) do
          heartbeat!
          next if timed_out

          if @stop_requested.call
            stopped = true
            terminate(wait_thread.pid)
            next
          end

          if kill_poll.call(Process.clock_gettime(Process::CLOCK_MONOTONIC))
            operator_killed = true
            terminate(wait_thread.pid)
            next
          end

          case @last_silent_kill
          when :aliveness
            aliveness_failed = true
            @last_silent_kill = nil
            terminate(wait_thread.pid)
          when :silent
            silent_timed_out = true
            @last_silent_kill = nil
            terminate(wait_thread.pid)
          end
        end

        @stdin_writer&.join
        killer.kill
        status = wait_thread.value
        process_exit_status = status.exitstatus || 1
        clean_exit_after_aliveness =
          aliveness_failed &&
          process_exit_status.zero? &&
          !timed_out &&
          !stopped &&
          !silent_timed_out &&
          !operator_killed
        aliveness_failed = false if clean_exit_after_aliveness

        result = Result.new(
          exit_status: (timed_out || silent_timed_out || aliveness_failed || operator_killed) ? nil : process_exit_status,
          timed_out: timed_out,
          stopped: stopped,
          silent_timed_out: silent_timed_out,
          operator_killed: operator_killed,
          aliveness_failed: aliveness_failed,
          duration_s: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at,
          spawned_process_id: @spawned_process&.id
        )
      end
    rescue StandardError
      finalize_spawned_process!(outcome: "failed", exit_status: nil)
      raise
    end

    finalize_spawned_process!(outcome: outcome_for(result), exit_status: result.exit_status)
    result
  end

  private

  def register_spawned_process
    return nil unless @kind

    SpawnedProcess.create!(
      kind: @kind,
      command: command_string,
      workdir: @chdir.presence,
      hostname: Socket.gethostname,
      started_at: Time.current,
      wall_timeout_s: @timeout&.to_i,
      silent_timeout_s: @silent_timeout&.to_i,
      run: @run,
      workflow: @workflow
    )
  end

  def update_pid!(pid)
    return unless @spawned_process

    pgid = if @pgroup
      begin
        Process.getpgid(pid)
      rescue Errno::ESRCH
        nil
      end
    end
    @spawned_process.update!(pid: pid, pgid: pgid)
  rescue StandardError => e
    Rails.logger.warn("[ProcessRunner] failed to record pid #{pid}: #{e.class}: #{e.message}")
  end

  def heartbeat!
    return unless @spawned_process

    now = Time.current
    last = @spawned_process.last_chunk_at
    return if last && (now - last) < HEARTBEAT_INTERVAL_SECONDS

    @spawned_process.update_column(:last_chunk_at, now)
    heartbeat_run!(now)
  rescue StandardError => e
    Rails.logger.warn("[ProcessRunner] heartbeat failed: #{e.class}: #{e.message}")
  end

  def heartbeat_run!(now)
    return unless @run

    Run.where(id: @run.id, finished_at: nil).update_all(last_heartbeat_at: now)
  end

  # Conditional UPDATE races safely with SpawnedProcessSupervisor#tick,
  # which uses the same WHERE finished_at IS NULL pattern. Whichever
  # transaction commits first wins; the loser silently no-ops. In the
  # rare race where the supervisor wins (subprocess exited microseconds
  # before our wait_thread noticed), the row keeps the supervisor's
  # "orphaned" guess instead of our accurate outcome — acceptable
  # fidelity loss for the simpler synchronization story.
  def finalize_spawned_process!(outcome:, exit_status:)
    return unless @spawned_process

    finished_at = Time.current
    rows = SpawnedProcess.where(id: @spawned_process.id, finished_at: nil)
                         .update_all(
                           finished_at: finished_at,
                           outcome: outcome,
                           exit_status: exit_status
                         )
    if rows.zero?
      Rails.logger.info("[ProcessRunner] SpawnedProcess ##{@spawned_process.id} already finalized (supervisor beat us)")
    else
      ChatStopReconciler.reconcile_spawned_process!(@spawned_process, finished_at: finished_at)
    end
  rescue StandardError => e
    Rails.logger.warn("[ProcessRunner] finalize failed: #{e.class}: #{e.message}")
  end

  def outcome_for(result)
    return "operator_killed" if result.operator_killed?
    return "aliveness_failed" if result.aliveness_failed?
    return "silent_timed_out" if result.silent_timed_out?
    return "timed_out" if result.timed_out?
    return "stopped" if result.stopped?
    return "succeeded" if result.success?

    "failed"
  end

  def command_string
    CommandRedactor.redact(@display_command.presence || @command.compact.map(&:to_s).join(" ")).safe_byteslice(0, 4096)
  end

  # Feed the child's stdin. When there is a payload, write it on a separate
  # thread so the caller can start draining stdout immediately. A synchronous
  # write of a large payload would deadlock: once the ~64 KiB stdin pipe buffer
  # fills we would block writing stdin, while the child can be simultaneously
  # blocked writing stdout that nobody is reading yet. The writer thread is
  # joined after stream_output finishes (see #run).
  def write_stdin(stdin)
    unless @stdin_data
      stdin.close unless stdin.closed?
      return
    end

    @stdin_writer = Thread.new do
      Thread.current.report_on_exception = false
      stdin.write(@stdin_data)
    rescue Errno::EPIPE, IOError
      # Child closed stdin before consuming the whole payload (e.g. it exited
      # early or read only what it needed). It already has what it read.
    ensure
      stdin.close unless stdin.closed?
    end
  end

  def stream_output(output, wait_thread, silent_check)
    line_buffer = +""
    last_chunk_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    loop do
      # The yield block is given a chance to terminate the process
      # based on the stop_requested / silent_timeout / kill_requested
      # signals. The `@last_silent_kill` flag we set just below tells
      # the block what reason to record before killing.
      @last_silent_kill = silent_check.call(last_chunk_at)
      yield
      break if wait_thread.respond_to?(:join) && wait_thread.join(0)

      ready, = IO.select([ output ], nil, nil, 0.1)
      next unless ready

      begin
        chunk = output.read_nonblock(READ_CHUNK_BYTES)
        last_chunk_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        heartbeat!
        @on_output_chunk&.call(chunk)
        stream_lines(chunk, line_buffer)
      rescue IO::WaitReadable
        next
      rescue EOFError
        break
      end
    end

    drain_output(output, line_buffer)
    @on_output_line&.call(line_buffer) if @on_output_line && !line_buffer.empty?
  end

  def drain_output(output, line_buffer)
    loop do
      chunk = output.read_nonblock(READ_CHUNK_BYTES)
      @on_output_chunk&.call(chunk)
      stream_lines(chunk, line_buffer)
    rescue IO::WaitReadable
      ready, = IO.select([ output ], nil, nil, 0)
      next if ready
      break
    rescue EOFError
      break
    end
  end

  def stream_lines(chunk, line_buffer)
    return unless @on_output_line

    line_buffer << chunk
    while (newline = line_buffer.index("\n"))
      @on_output_line.call(line_buffer.slice!(0..newline))
    end
  end

  def terminate(pid)
    Process.kill("TERM", -pid)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @kill_grace_seconds
    loop do
      Process.kill(0, -pid)
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.1
    end
    Process.kill("KILL", -pid)
  rescue Errno::ESRCH
    # Already dead.
  end
end
