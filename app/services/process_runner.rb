require "open3"
require "socket"
require "ipaddr"
require "fileutils"
require "pathname"
require "tempfile"

# Small shared wrapper for subprocess lifetime management. Callers still own
# command construction and output parsing; this class owns the boring parts:
# scrubbed env, process-group spawning, timeout/stop handling, streaming,
# SpawnedProcess registration + heartbeats + the operator kill switch, and
# a common result shape.
class ProcessRunner
  class WorkspaceAttributionError < StandardError; end
  class MountAssertionError < StandardError; end
  class NetworkAssertionError < StandardError; end

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
  KILL_POLL_INTERVAL_SECONDS = 5
  SPAWNED_PROCESS_HEARTBEAT_INTERVAL_SECONDS = 120
  SYNC_STDIN_BYTES = 32 * 1024
  # Live process resource samples are useful for the admin UI, but the JSON
  # update is a hot write on long-running agent/grader processes. Persist
  # sparingly while running; finalization always writes the final attribution.
  RESOURCE_ATTRIBUTION_UPDATE_INTERVAL_SECONDS = 5 * 60

  Mount = Data.define(:host_path, :mount_path) do
    def initialize(host_path:, mount_path: nil)
      host = Pathname.new(host_path.to_s).expand_path
      super(host_path: host.to_s, mount_path: (mount_path || host).to_s)
    end

    def include?(path)
      path = Pathname.new(path.to_s).expand_path
      root = Pathname.new(host_path).expand_path
      relative = path.relative_path_from(root).to_s
      relative == "." || !relative.start_with?("../")
    rescue ArgumentError
      false
    end

    def to_h
      { host_path: host_path, mount_path: mount_path }
    end
  end

  Mounts = Data.define(:workdir, :read_write, :read_only, :artifacts) do
    def initialize(workdir:, read_write:, read_only: [], artifacts: nil)
      workdir_path = Pathname.new(workdir.to_s).expand_path.to_s
      rw = Array(read_write).map { |mount| ProcessRunner.normalize_mount(mount) }
      ro = Array(read_only).map { |mount| ProcessRunner.normalize_mount(mount) }
      artifact_mount = artifacts ? ProcessRunner.normalize_mount(artifacts) : nil
      super(workdir: workdir_path, read_write: rw, read_only: ro, artifacts: artifact_mount)
    end

    def writable_mounts
      [ *read_write, artifacts ].compact
    end

    def declared_mounts
      [ *read_write, *read_only, artifacts ].compact
    end

    def writable?(path)
      writable_mounts.any? { |mount| mount.include?(path) }
    end

    def read_only?(path)
      read_only.any? { |mount| mount.include?(path) }
    end

    def declared?(path)
      declared_mounts.any? { |mount| mount.include?(path) }
    end

    def to_h
      {
        workdir: workdir,
        read_write: read_write.map(&:to_h),
        read_only: read_only.map(&:to_h),
        artifacts: artifacts&.to_h
      }.compact
    end
  end

  MountAccess = Data.define(:path, :mode) do
    def write?
      mode == :write
    end
  end

  NetworkAccess = Data.define(:address, :port, :family) do
    LOOPBACK_V4 = IPAddr.new("127.0.0.0/8")
    LOOPBACK_V6 = IPAddr.new("::1")

    def loopback?
      return true if address.to_s == "localhost"

      ip = IPAddr.new(address)
      LOOPBACK_V4.include?(ip) || LOOPBACK_V6.include?(ip)
    rescue IPAddr::InvalidAddressError
      false
    end
  end

  module NetworkProfile
    class Base
      attr_reader :name

      def initialize(name)
        @name = name
      end

      def network_access_violation(_access)
        nil
      end
    end

    class Grader < Base
      def initialize = super("grader")

      def network_access_violation(access)
        return nil if access.loopback?

        "non-local egress to #{access.address}#{":#{access.port}" if access.port}"
      end
    end

    class Prepare < Base
      def initialize = super("prepare")
    end

    class Agent < Base
      def initialize = super("agent")
    end

    class GitFetch < Base
      def initialize = super("git_fetch")
    end

    PROFILES = {
      "grader" => Grader.new,
      "prepare" => Prepare.new,
      "agent" => Agent.new,
      "git_fetch" => GitFetch.new
    }.freeze

    def self.for(value)
      PROFILES.fetch(value.to_s) do
        raise ArgumentError, "unknown ProcessRunner network profile #{value.inspect}; expected #{PROFILES.keys.join(', ')}"
      end
    end
  end

  class MountTraceParser
    DESTINATION_WRITE_SYSCALLS = %w[
      link linkat rename renameat renameat2 symlink symlinkat
    ].freeze
    ALL_PATH_WRITE_SYSCALLS = %w[
      rename renameat renameat2
    ].freeze
    WRITE_SYSCALLS = %w[
      creat mkdir mkdirat mknod mknodat open openat openat2 rename renameat
      renameat2 rmdir symlink symlinkat link linkat unlink unlinkat truncate
      ftruncate chmod fchmodat chown fchownat lchown utime utimes utimensat
    ].freeze
    READ_SYSCALLS = %w[
      access faccessat faccessat2 stat statx lstat newfstatat readlink
      readlinkat execve
    ].freeze
    PATH_ARGUMENT_SYSCALLS = (WRITE_SYSCALLS + READ_SYSCALLS + %w[chdir]).uniq.freeze

    def initialize(trace_path, initial_cwd:)
      @trace_path = trace_path
      @initial_cwd = Pathname.new(initial_cwd.to_s).expand_path.to_s
      @cwd_by_pid = Hash.new(@initial_cwd)
    end

    def accesses
      return [] unless File.exist?(@trace_path)

      File.readlines(@trace_path, chomp: true).flat_map { |line| accesses_for(line) }
    end

    private

    def accesses_for(line)
      pid, syscall, args, success = parse_line(line)
      return [] unless success
      return [] unless PATH_ARGUMENT_SYSCALLS.include?(syscall)

      paths = path_args(args)
      return [] if paths.empty?

      if syscall == "chdir"
        record_chdir(pid, absolute_path(paths.first, cwd: @cwd_by_pid[pid]))
        return []
      end

      paths.each_with_index.map do |path, index|
        MountAccess.new(
          path: absolute_path(path, cwd: @cwd_by_pid[pid]),
          mode: access_mode(syscall, args, index, paths.length)
        )
      end
    end

    def parse_line(line)
      text = line.to_s
      pid = text[/\A\d+/]&.to_i
      text = text.sub(/\A\d+\s+/, "")
      match = text.match(/\A(?<syscall>\w+)\((?<args>.*)\)\s+=\s+(?<result>-?\d+|0x[0-9a-f]+|\?)/)
      return [ pid || 0, nil, nil, false ] unless match

      result = match[:result]
      success = result == "?" || result.to_i >= 0
      [ pid || 0, match[:syscall], match[:args], success ]
    end

    def path_args(args)
      args.to_s.scan(/"((?:\\.|[^"\\])*)"/).flatten.reject { |path| path == "." || path == ".." }
    end

    def absolute_path(path, cwd:)
      decoded = path.to_s.gsub(/\\x([0-9a-fA-F]{2})/) { Regexp.last_match(1).hex.chr }
      pathname = Pathname.new(decoded)
      pathname = Pathname.new(cwd).join(pathname) unless pathname.absolute?
      pathname.cleanpath.to_s
    end

    def record_chdir(pid, path)
      @cwd_by_pid[pid] = path
    end

    def access_mode(syscall, args, index, path_count)
      return :write if ALL_PATH_WRITE_SYSCALLS.include?(syscall)
      return index == path_count - 1 ? :write : :read if DESTINATION_WRITE_SYSCALLS.include?(syscall)
      write_access?(syscall, args) ? :write : :read
    end

    def write_access?(syscall, args)
      return true if WRITE_SYSCALLS.include?(syscall) && syscall != "open" && syscall != "openat" && syscall != "openat2"

      args.to_s.match?(/\b(O_WRONLY|O_RDWR|O_CREAT|O_TRUNC|O_APPEND)\b/)
    end
  end

  class NetworkTraceParser
    def initialize(trace_path)
      @trace_path = trace_path
    end

    def accesses
      return [] unless File.exist?(@trace_path)

      File.readlines(@trace_path, chomp: true).filter_map { |line| access_for(line) }
    end

    private

    def access_for(line)
      return nil unless line.match?(/\bconnect\(/)

      address = ipv4_address(line) || ipv6_address(line) || localhost_address(line)
      return nil unless address

      NetworkAccess.new(address: address, port: port(line), family: family(line))
    end

    def ipv4_address(line)
      line[/inet_addr\("([^"]+)"\)/, 1]
    end

    def ipv6_address(line)
      line[/inet_pton\(AF_INET6,\s*"([^"]+)"/, 1]
    end

    def localhost_address(line)
      "localhost" if line.include?("AF_UNIX")
    end

    def port(line)
      raw = line[/sin6?_port=htons\((\d+)\)/, 1]
      raw&.to_i
    end

    def family(line)
      line[/sa_family=(AF_[A-Z0-9_]+)/, 1]
    end
  end

  def self.forwarded_env(keys, extra: {})
    ENV.slice(*keys).merge(extra.compact)
  end

  def self.mounts(workdir, read_write: nil, read_only: [], artifacts: nil)
    Mounts.new(workdir: workdir, read_write: read_write || workdir, read_only: read_only, artifacts: artifacts)
  end

  def self.normalize_mounts(value)
    return value if value.is_a?(Mounts)

    hash = value.to_h
    Mounts.new(
      workdir: hash[:workdir] || hash["workdir"],
      read_write: hash[:read_write] || hash["read_write"],
      read_only: hash[:read_only] || hash["read_only"] || [],
      artifacts: hash[:artifacts] || hash["artifacts"]
    )
  end

  def self.normalize_mount(value)
    return value if value.is_a?(Mount)

    if value.respond_to?(:to_h)
      hash = value.to_h
      host_path = hash[:host_path] || hash["host_path"]
      mount_path = hash[:mount_path] || hash["mount_path"]
      return Mount.new(host_path: host_path, mount_path: mount_path)
    end

    Mount.new(host_path: value)
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
  def initialize(env:, command:, mounts:, network:, timeout:, stdin_data: nil,
                 unsetenv_others: true, pgroup: true,
                 stop_requested: -> { false },
                 on_output_chunk: nil,
                 on_output_line: nil,
                 kill_grace_seconds: TERM_GRACE_SECONDS,
                 silent_timeout: nil,
                 kind: nil,
                 run: nil,
                 workflow: nil,
                 job: nil,
                 chat_session: nil,
                 agent: nil,
                 display_command: nil,
                 on_spawned_process: nil)
    @env = env
    @command = command
    @mounts = self.class.normalize_mounts(mounts)
    @network = NetworkProfile.for(network)
    @chdir = @mounts.workdir
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
    @workflow = resolve_workflow_attribution(workflow)
    @job = job || @run&.job || @workflow&.job || Thread.current[:syrus_current_job]
    @chat_session = chat_session
    @agent = agent
    @display_command = display_command
    @on_spawned_process = on_spawned_process

    # Idempotent — only the first call in this process spawns the
    # supervisor thread. Web pods never reach this code path so they
    # never get a supervisor thread (nothing to supervise there).
    SpawnedProcessSupervisor.ensure_running if @kind
  end

  def run
    with_workspace_lock { run_process }
  end

  private

  # Held for the lifetime of the spawned subprocess so
  # WorkflowWorkspace.cleanup_for's non-blocking exclusive flock on the
  # same sentinel file can detect a still-live process and defer rm_rf,
  # even when the DB-tracked SpawnedProcess/Run rows look stale (the
  # heartbeat/poll signal cleanup_for otherwise relies on). Shared so
  # multiple subprocesses can run concurrently in the same workspace
  # (e.g. a landing fanout's parallel grader Runs).
  def with_workspace_lock
    return yield unless @workflow

    lock_path = WorkflowWorkspace.lock_path_for(@workflow)
    FileUtils.mkdir_p(lock_path.dirname)
    File.open(lock_path, File::CREAT | File::RDWR) do |lock_file|
      lock_file.flock(File::LOCK_SH)
      begin
        yield
      ensure
        lock_file.flock(File::LOCK_UN)
      end
    end
  end

  def resolve_workflow_attribution(workflow)
    workflow_id = workflow_id_from_chdir
    return workflow unless workflow_id

    if workflow && workflow.id != workflow_id
      raise WorkspaceAttributionError,
            "ProcessRunner chdir #{@chdir} is inside Workflow ##{workflow_id}, but workflow ##{workflow.id} was supplied"
    end

    Workflow.find_by(id: workflow_id) ||
      raise(WorkspaceAttributionError, "ProcessRunner chdir #{@chdir} is inside Workflow ##{workflow_id}, but no Workflow row exists")
  end

  def workflow_id_from_chdir
    root = WorkflowWorkspace.data_root.join("workflows").expand_path
    chdir_path = Pathname.new(@chdir).expand_path
    relative = chdir_path.relative_path_from(root)
    return nil if relative.to_s == "."
    return nil if relative.to_s.start_with?("../")

    first = relative.each_filename.first
    return nil unless first.to_s.match?(/\A\d+\z/)

    Integer(first)
  rescue ArgumentError
    nil
  end

  def run_process
    timed_out = false
    stopped = false
    silent_timed_out = false
    operator_killed = false
    aliveness_failed = false
    result = nil
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    effective_command = command_with_local_execution_request_assertions

    @spawned_process = register_spawned_process
    @on_spawned_process&.call(@spawned_process) if @spawned_process

    spawn_started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    begin
      Open3.popen2e(@env, *effective_command,
                    chdir: @chdir,
                    unsetenv_others: @unsetenv_others,
                    pgroup: @pgroup) do |stdin, output, wait_thread|
        record_chat_process_spawn_latency!(spawn_started_at)
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
          # SpawnedProcess#kill_requested_at; poll coarsely so long-running
          # graders do not turn operator-kill checks into DB read pressure.
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
        sample_resource_attribution!
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

      assert_local_execution_request! if result
    rescue StandardError
      finalize_spawned_process!(outcome: "failed", exit_status: nil)
      raise
    end

    finalize_spawned_process!(outcome: outcome_for(result), exit_status: result.exit_status)
    result
  end

  private

  def command_with_local_execution_request_assertions
    return @command unless local_execution_request_assertions_enabled?

    strace = find_executable("strace")
    unless strace
      raise MountAssertionError, "execution_request_assertions requires strace on the local backend"
    end

    @execution_request_assertion_trace_path = Tempfile.new([ "syrus-process-runner-execution-request-", ".strace" ])
    @execution_request_assertion_trace_path.close
    [ strace, "-f", "-e", "trace=file,network", "-qq", "-o", @execution_request_assertion_trace_path.path, "--", *@command ]
  end

  def local_execution_request_assertions_enabled?
    Feature.execution_request_assertions_enabled?
  rescue StandardError
    false
  end

  def find_executable(name)
    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |dir|
      path = File.join(dir, name)
      return path if File.executable?(path) && !File.directory?(path)
    end
    nil
  end

  def assert_local_execution_request!
    return unless @execution_request_assertion_trace_path

    assert_local_mount_accesses!
    assert_local_network_accesses!
  ensure
    @execution_request_assertion_trace_path&.unlink
  end

  def assert_local_mount_accesses!
    accesses = MountTraceParser.new(@execution_request_assertion_trace_path.path, initial_cwd: @chdir).accesses
    violations = accesses.filter_map { |access| mount_access_violation(access) }
    return if violations.empty?

    raise MountAssertionError, "execution request mount declaration mismatch: #{violations.uniq.first(5).join('; ')}"
  end

  def assert_local_network_accesses!
    accesses = NetworkTraceParser.new(@execution_request_assertion_trace_path.path).accesses
    violations = accesses.filter_map { |access| @network.network_access_violation(access) }
    return if violations.empty?

    raise NetworkAssertionError, "execution request network declaration mismatch for #{@network.name}: #{violations.uniq.first(5).join('; ')}"
  end

  def mount_access_violation(access)
    return nil unless assertion_scoped_path?(access.path)

    if access.write? && @mounts.read_only?(access.path)
      return "write to read-only mount #{access.path}"
    end

    if access.write? && !@mounts.writable?(access.path)
      return "write outside writable mounts #{access.path}"
    end

    return nil if @mounts.declared?(access.path)

    "access outside declared mounts #{access.path}"
  end

  def assertion_scoped_path?(path)
    return true if @mounts.declared?(path)

    data_root = WorkflowWorkspace.data_root.expand_path
    absolute = Pathname.new(path.to_s).expand_path
    relative = absolute.relative_path_from(data_root).to_s
    relative == "." || !relative.start_with?("../")
  rescue ArgumentError
    false
  end

  # Only chat-attributed spawns (the "process spawn" stage of chat startup
  # latency) report here -- workflow/grader spawns already have separate
  # Run/CommandSpan-based worker health correlation (see
  # read_run_worker_health) and shouldn't be double-counted under a phase
  # name that promises chat scope.
  def record_chat_process_spawn_latency!(spawn_started_at)
    return unless @chat_session

    duration_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - spawn_started_at) * 1000.0
    PerformanceLogging.report_duration(
      "chat_startup.process_spawn",
      duration_ms,
      metadata: { kind: @kind.to_s, chat_session_id: @chat_session.id }.compact,
      capture_host_pressure: true
    )
  rescue StandardError
    nil
  end

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
      workflow: @workflow,
      job: @job,
      chat_session: @chat_session,
      agent: @agent
    ).tap do |process|
      Thread.current[:syrus_current_job_classification_attempt]&.update_columns(spawned_process_id: process.id)
    end
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
    @resource_sampler = ProcessResourceSampler.new(pid: pid, pgid: pgid)
    sample_resource_attribution!
    @spawned_process.update!(
      pid: pid,
      pgid: pgid,
      resource_attribution: current_resource_attribution
    )
    @last_resource_attribution_persisted_at = Time.current
  rescue StandardError => e
    Rails.logger.warn("[ProcessRunner] failed to record pid #{pid}: #{e.class}: #{e.message}")
  end

  def heartbeat!
    heartbeat_run!(Time.current)
    return unless @spawned_process

    now = Time.current
    last = @spawned_process.last_chunk_at
    return if last && (now - last) < SPAWNED_PROCESS_HEARTBEAT_INTERVAL_SECONDS

    if persist_resource_attribution?(now)
      sample_resource_attribution!
      @spawned_process.update_columns(
        last_chunk_at: now,
        resource_attribution: current_resource_attribution
      )
      @last_resource_attribution_persisted_at = now
    else
      @spawned_process.update_columns(last_chunk_at: now)
    end
  rescue StandardError => e
    Rails.logger.warn("[ProcessRunner] heartbeat failed: #{e.class}: #{e.message}")
  end

  def heartbeat_run!(now)
    return unless @run

    RunHeartbeat.touch(@run, now: now)
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

    sample_resource_attribution!
    resource_attribution = current_resource_attribution
    finished_at = Time.current
    rows = SpawnedProcess.where(id: @spawned_process.id, finished_at: nil)
                         .update_all(
                           finished_at: finished_at,
                           outcome: outcome,
                           exit_status: exit_status,
                           resource_attribution: resource_attribution
                         )
    if rows.zero?
      Rails.logger.info("[ProcessRunner] SpawnedProcess ##{@spawned_process.id} already finalized (supervisor beat us)")
    else
      CommandSpan.where(spawned_process_id: @spawned_process.id).find_each do |span|
        span.update_column(:resource_attribution, command_span_process_owned_payload)
      end
      return if ChatTurnAutoRetryReconciler.reconcile_spawned_process!(@spawned_process, finished_at: finished_at)

      ChatStopReconciler.reconcile_spawned_process!(@spawned_process, finished_at: finished_at)
    end
  rescue StandardError => e
    Rails.logger.warn("[ProcessRunner] finalize failed: #{e.class}: #{e.message}")
  end

  def sample_resource_attribution!
    @resource_sampler&.sample!
  end

  def persist_resource_attribution?(now)
    return false unless @resource_sampler
    return true unless @last_resource_attribution_persisted_at

    (now - @last_resource_attribution_persisted_at) >= RESOURCE_ATTRIBUTION_UPDATE_INTERVAL_SECONDS
  end

  def current_resource_attribution
    @resource_sampler&.payload || {}
  end

  def command_span_process_owned_payload
    {
      "method" => "spawned_process_owned",
      "version" => ProcessResourceSampler::VERSION,
      "confidence" => "low",
      "sample_count" => 0,
      "unavailable_reason" => "process-group resource attribution is owned by the spawned process"
    }
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

  # Feed the child's stdin. Write a bounded prefix synchronously so children
  # with short stdin-wait windows observe input before the async writer can be
  # delayed by host CPU/IO pressure. Payloads larger than the safe prefix still
  # finish on a separate thread so the caller can drain stdout immediately; a
  # fully synchronous large write could deadlock once the pipe buffer fills.
  def write_stdin(stdin)
    unless @stdin_data
      stdin.close unless stdin.closed?
      return
    end

    remaining = write_stdin_prefix(stdin)
    if remaining.empty?
      stdin.close unless stdin.closed?
      return
    end

    @stdin_writer = Thread.new(remaining) do |payload|
      Thread.current.report_on_exception = false
      Thread.current.priority = [ Thread.current.priority, 1 ].max
      stdin.write(payload)
    rescue Errno::EPIPE, IOError
      # Child closed stdin before consuming the whole payload (e.g. it exited
      # early or read only what it needed). It already has what it read.
    ensure
      stdin.close unless stdin.closed?
    end
  end

  def write_stdin_prefix(stdin)
    prefix = @stdin_data.byteslice(0, SYNC_STDIN_BYTES)
    remaining = @stdin_data.byteslice(SYNC_STDIN_BYTES..) || +""
    stdin.write(prefix)
    remaining
  rescue Errno::EPIPE, IOError
    +""
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
