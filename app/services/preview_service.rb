require "net/http"
require "set"
require "socket"

# Long-running service that manages preview environment child processes.
#
# Lifecycle:
#   - Polls `PreviewEnvironment` records in `starting` state every ~2s.
#   - Allocates a free port from the configured range.
#   - Spawns the app process, runs an optional seed command, polls the health
#     check path, then marks the environment `running`.
#   - Every ~30s, kills and marks `stopped` any environment whose `expires_at`
#     has passed.
#   - On SIGTERM: marks all managed environments `stopping` → `stopped`, waits
#     for child processes to exit (up to 10s each), then exits cleanly.
#
# All database access is done on a dedicated ActiveRecord connection so the
# service can run outside the web/worker process.
class PreviewService
  PORT_MIN = Integer(ENV.fetch("SYRUS_PREVIEW_PORT_MIN", PreviewEnvironment::DEFAULT_PORT_MIN))
  PORT_MAX = Integer(ENV.fetch("SYRUS_PREVIEW_PORT_MAX", PreviewEnvironment::DEFAULT_PORT_MAX))
  INTERNAL_HOST = ENV.fetch("SYRUS_PREVIEW_INTERNAL_HOST", "127.0.0.1")

  POLL_INTERVAL_SECONDS = 2
  TTL_CHECK_INTERVAL_SECONDS = 30
  HEALTH_CHECK_TIMEOUT_SECONDS = 120
  HEALTH_CHECK_RETRY_INTERVAL_SECONDS = 2
  GRACEFUL_SHUTDOWN_TIMEOUT_SECONDS = 10
  CHILD_HEARTBEAT_INTERVAL_SECONDS = ProcessRunner::SPAWNED_PROCESS_HEARTBEAT_INTERVAL_SECONDS

  ChildProcess = Struct.new(:pid, :environment_id, :port, :spawned_process_id, keyword_init: true)

  # Raised when the local health check passes but the internal proxy host
  # can't reach the app — the fixable "bind to 0.0.0.0" case. Tagged
  # separately so PreviewEnvironment#error_reason can drive a "Fix preview"
  # remediation action in the UI instead of a plain failure message.
  class NotReachableError < RuntimeError; end

  def initialize
    @children = {}  # environment_id → ChildProcess
    @mutex = Mutex.new
    @shutting_down = false
    @last_ttl_check = Time.current
  end

  def run
    trap_signals!
    Rails.logger.info("[PreviewService] starting")

    loop do
      break if @shutting_down

      with_connection do
        poll_starting_environments
        poll_stopping_environments
        check_ttl_expirations if ttl_check_due?
        heartbeat_children!
        honor_kill_requests!
        reconcile_finished_spawned_processes!
        reap_exited_children
      end

      sleep POLL_INTERVAL_SECONDS
    end
  ensure
    shutdown_gracefully
  end

  def self.port_in_use?(port)
    TCPSocket.new("127.0.0.1", port).close
    true
  rescue Errno::ECONNREFUSED, Errno::ETIMEDOUT
    false
  end

  private

  def trap_signals!
    Signal.trap("TERM") { initiate_shutdown }
    Signal.trap("INT")  { initiate_shutdown }
  end

  def initiate_shutdown
    @shutting_down = true
  end

  def with_connection(&block)
    ActiveRecord::Base.connection_pool.with_connection(&block)
  end

  def poll_starting_environments
    PreviewEnvironment.where(state: "starting").find_each do |env|
      next if @children.key?(env.id)

      start_environment(env)
    rescue => e
      Rails.logger.error("[PreviewService] error starting environment #{env.id}: #{e.class}: #{e.message}")
      reason = e.is_a?(NotReachableError) ? "not_reachable" : nil
      with_connection { mark_failed(env, e.message, reason: reason) }
    end
  end

  def poll_stopping_environments
    PreviewEnvironment.where(state: "stopping").find_each do |env|
      stop_environment(env)
    end
  end

  def start_environment(env)
    workspace_path = ensure_workspace!(env)

    source = PreviewCommandSource.new(workspace_path).resolve
    unless source
      mark_failed(env, "no preview command configured for this repository")
      return
    end

    port = allocate_port
    unless port
      mark_failed(env, "no free preview port available")
      return
    end

    env.update_columns(port: port, internal_host: INTERNAL_HOST)
    env.begin_seeding! && env.save!

    process_env = preview_process_env(source, workspace_path)

    run_setup_commands(source, workspace_path, process_env)
    return if stop_requested?(env)

    run_seed_command(source, workspace_path, process_env) if source.seed_command
    return if stop_requested?(env)

    child = spawn_app(source.start_command_for.call(port: port), workspace_path, port, env, process_env)
    @mutex.synchronize { @children[env.id] = child }

    await_health_check(env, port, source.health_check_path)
  end

  def run_seed_command(source, workspace_path, process_env)
    run_preview_command!("seed", source.seed_command, workspace_path, process_env)
  end

  def run_setup_commands(source, workspace_path, process_env)
    Array(source.setup_commands).each do |command|
      run_preview_command!("setup", command, workspace_path, process_env)
    end
  end

  def run_preview_command!(label, command, workspace_path, process_env)
    Rails.logger.info("[PreviewService] running #{label}: #{command}")
    result = system(process_env, "bash", "-c", command, chdir: workspace_path, exception: false, unsetenv_others: true)
    raise "preview #{label} command exited non-zero: #{command}" unless result
  end

  def ensure_workspace!(env)
    workspace_path = env.workspace_path
    return workspace_path if workspace_path.present? && Dir.exist?(workspace_path)

    PreviewWorkspace.prepare!(env, revision: workspace_revision_for(env.job))
  end

  # A closed, landed Job's branch is typically already deleted by the time an
  # operator starts a post-land preview — clone by the merged commit SHA
  # instead of the (gone) branch name. Every other previewable state still
  # has a live branch to check out directly. A repository-scoped preview (no
  # Job) has no revision to resolve at all — PreviewWorkspace's :head default
  # already clones the repository's default branch in that case.
  def workspace_revision_for(job)
    return :head unless job

    job.closed? && job.landed_sha.present? ? :commit_sha : :head
  end

  def stop_requested?(env)
    env.reload
    return false unless env.stopping?

    stop_environment(env)
    true
  end

  def spawn_app(command, workspace_path, port, preview_environment, process_env = {})
    env = process_env.merge("PORT" => port.to_s)
    pid = Process.spawn(env, command, chdir: workspace_path, pgroup: true,
                                      out: "/dev/null", err: "/dev/null",
                                      unsetenv_others: true)
    pgid = Process.getpgid(pid) rescue nil
    spawned_process = SpawnedProcess.create!(
      kind: "preview",
      command: command,
      workdir: workspace_path,
      hostname: Socket.gethostname,
      started_at: Time.current,
      last_chunk_at: Time.current,
      pid: pid,
      pgid: pgid,
      resource_attribution: {
        "preview_environment_id" => preview_environment.id,
        "job_id" => preview_environment.job_id,
        "repository_id" => preview_environment.repository_id,
        "port" => port
      }
    )
    SpawnedProcessSupervisor.ensure_running
    Rails.logger.info("[PreviewService] spawned pid=#{pid} port=#{port} cmd=#{command.inspect}")
    ChildProcess.new(pid: pid, environment_id: preview_environment.id, port: port, spawned_process_id: spawned_process.id)
  end

  def preview_process_env(source, workspace_path)
    env = ProcessRunner.forwarded_env(
      Steps::Prepare::PREP_ENV_FORWARD,
      extra: WorkspaceDependencyEnv.for(workspace_path)
    )
    Array(source.unset_env).each { |name| env[name.to_s] = nil }
    env.merge!(source.env || {})
    env
  end

  def await_health_check(env, port, health_check_path)
    deadline = Time.current + HEALTH_CHECK_TIMEOUT_SECONDS
    loop do
      break if @shutting_down
      raise "health check timed out after #{HEALTH_CHECK_TIMEOUT_SECONDS}s" if Time.current > deadline

      child = @mutex.synchronize { @children[env.id] }
      unless child
        raise "child process for environment #{env.id} disappeared before health check passed"
      end
      if child_exited?(child)
        @mutex.synchronize { @children.delete(env.id) }
        raise "preview process exited before health check passed"
      end

      if http_ok?(local_health_check_url(port, health_check_path))
        validate_proxy_reachability!(port, health_check_path)
        with_connection do
          env.reload
          env.mark_running! && env.save!
          env.touch_activity!
        end
        Rails.logger.info("[PreviewService] environment #{env.id} is running on port #{port}")
        return
      end

      sleep HEALTH_CHECK_RETRY_INTERVAL_SECONDS
    end
  end

  def local_health_check_url(port, health_check_path)
    "http://127.0.0.1:#{port}#{health_check_path}"
  end

  def proxy_health_check_url(port, health_check_path)
    "http://#{INTERNAL_HOST}:#{port}#{health_check_path}"
  end

  def validate_proxy_reachability!(port, health_check_path)
    return if loopback_internal_host?

    url = proxy_health_check_url(port, health_check_path)
    return if http_ok?(url)

    raise NotReachableError, "preview process is healthy on 127.0.0.1:#{port} but is not reachable at #{INTERNAL_HOST}:#{port}; configure the preview start command to bind to 0.0.0.0"
  end

  def loopback_internal_host?
    INTERNAL_HOST.in?([ "127.0.0.1", "localhost", "::1" ])
  end

  def http_ok?(url)
    uri = URI.parse(url)
    response = Net::HTTP.start(uri.host, uri.port, open_timeout: 1, read_timeout: 2) do |http|
      http.get(uri.request_uri)
    end
    response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPRedirection)
  rescue Errno::ECONNREFUSED, Errno::ETIMEDOUT, Net::OpenTimeout, Net::ReadTimeout, SocketError
    false
  end

  def check_ttl_expirations
    @last_ttl_check = Time.current
    PreviewEnvironment.expired.find_each do |env|
      Rails.logger.info("[PreviewService] expiring environment #{env.id}")
      stop_environment(env)
    end
  end

  def ttl_check_due?
    Time.current - @last_ttl_check >= TTL_CHECK_INTERVAL_SECONDS
  end

  def reap_exited_children
    @mutex.synchronize { @children.dup }.each do |env_id, child|
      result = Process.waitpid2(child.pid, Process::WNOHANG)
      next unless result

      exit_status = result[1]
      @mutex.synchronize { @children.delete(env_id) }
      finalize_spawned_process(child, outcome: exit_status.success? ? "succeeded" : "failed", exit_status: exit_status.exitstatus)

      with_connection do
        env = PreviewEnvironment.find_by(id: env_id)
        next unless env

        if env.stopping?
          env.mark_stopped! && env.save!
          PreviewWorkspace.cleanup_for(env)
          Rails.logger.info("[PreviewService] environment #{env_id} stopped (pid=#{child.pid})")
        elsif exit_status.success?
          env.begin_stopping! && env.save!
          env.mark_stopped! && env.save!
          PreviewWorkspace.cleanup_for(env)
          Rails.logger.info("[PreviewService] environment #{env_id} exited cleanly")
        else
          mark_failed(env, "process exited unexpectedly with status #{exit_status.exitstatus}")
        end
      end
    end
  end

  def stop_environment(env)
    child = @mutex.synchronize { @children[env.id] }
    env.begin_stopping! && env.save! if env.may_begin_stopping?

    if child
      kill_process_group(child.pid)
    else
      env.mark_stopped! && env.save!
      PreviewWorkspace.cleanup_for(env)
    end
  end

  def kill_process_group(pid)
    Process.kill("-TERM", pid)
  rescue Errno::ESRCH, Errno::EPERM
    # Already gone.
  end

  def mark_failed(env, message, reason: nil)
    child = @mutex.synchronize { @children.delete(env.id) }
    if child
      kill_process_group(child.pid)
      finalize_spawned_process(child, outcome: "failed", exit_status: nil)
    end

    env.update_columns(error_message: message, error_reason: reason) if env.persisted?
    env.fail! && env.save! if env.may_fail?
    PreviewWorkspace.cleanup_for(env)
    Rails.logger.error("[PreviewService] environment #{env.id} failed: #{message}")
  end

  def child_exited?(child)
    result = Process.waitpid2(child.pid, Process::WNOHANG)
    return false unless result

    status = result[1]
    finalize_spawned_process(child, outcome: status.success? ? "succeeded" : "failed", exit_status: status.exitstatus)
    true
  rescue Errno::ECHILD
    SpawnedProcess.where(id: child.spawned_process_id).where.not(finished_at: nil).exists?
  end

  def process_alive?(pid)
    return false unless pid

    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    true
  end

  def heartbeat_children!
    ids = @mutex.synchronize { @children.values.filter_map(&:spawned_process_id) }
    return if ids.empty?

    now = Time.current
    SpawnedProcess
      .where(id: ids, finished_at: nil)
      .where("last_chunk_at IS NULL OR last_chunk_at < ?", now - CHILD_HEARTBEAT_INTERVAL_SECONDS.seconds)
      .update_all(last_chunk_at: now, updated_at: now)
  end

  def honor_kill_requests!
    children = @mutex.synchronize { @children.dup }
    return if children.empty?

    requested = SpawnedProcess.where(id: children.values.filter_map(&:spawned_process_id))
                              .where.not(kill_requested_at: nil)
                              .pluck(:id)
                              .to_set
    children.each do |env_id, child|
      next unless requested.include?(child.spawned_process_id)

      env = PreviewEnvironment.find_by(id: env_id)
      stop_environment(env) if env&.active?
    end
  end

  def reconcile_finished_spawned_processes!
    children = @mutex.synchronize { @children.dup }
    return if children.empty?

    finished = SpawnedProcess.where(id: children.values.filter_map(&:spawned_process_id))
                             .where.not(finished_at: nil)
                             .pluck(:id, :outcome)
                             .to_h
    children.each do |env_id, child|
      outcome = finished[child.spawned_process_id]
      next unless outcome
      if outcome == "orphaned" && process_alive?(child.pid)
        Rails.logger.warn("[PreviewService] ignoring orphaned SpawnedProcess ##{child.spawned_process_id}; pid #{child.pid} is still alive")
        next
      end

      @mutex.synchronize { @children.delete(env_id) }
      env = PreviewEnvironment.find_by(id: env_id)
      next unless env&.active?

      mark_failed(env, "preview process ended unexpectedly (#{outcome})")
    end
  end

  def finalize_spawned_process(child, outcome:, exit_status:)
    return unless child.spawned_process_id

    SpawnedProcess.where(id: child.spawned_process_id, finished_at: nil).update_all(
      finished_at: Time.current,
      outcome: outcome,
      exit_status: exit_status,
      updated_at: Time.current
    )
  end

  def allocate_port
    used = @mutex.synchronize { @children.values.map(&:port).to_set }
    used += PreviewEnvironment.where(state: PreviewEnvironment::ACTIVE_STATES)
                              .where.not(port: nil)
                              .pluck(:port).to_set
    candidates = (PORT_MIN..PORT_MAX).to_a.shuffle
    candidates.find { |p| !used.include?(p) && !self.class.port_in_use?(p) }
  end

  def shutdown_gracefully
    Rails.logger.info("[PreviewService] shutting down, stopping #{@children.size} child(ren)")

    with_connection do
      PreviewEnvironment.where(id: @children.keys).each do |env|
        env.begin_stopping! && env.save! if env.may_begin_stopping?
      end
    end

    @mutex.synchronize { @children.dup }.each do |_env_id, child|
      kill_process_group(child.pid)
    end

    deadline = Time.current + GRACEFUL_SHUTDOWN_TIMEOUT_SECONDS
    stopped_children = @mutex.synchronize { @children.dup }
    stopped_children.each do |env_id, child|
      remaining = [ deadline - Time.current, 0 ].max
      begin
        Timeout.timeout(remaining) { Process.waitpid(child.pid) }
      rescue Timeout::Error
        Rails.logger.warn("[PreviewService] pid #{child.pid} did not exit in time; force killing")
        begin
          Process.kill("-KILL", child.pid)
        rescue Errno::ESRCH
          # gone
        end
      end
      finalize_spawned_process(child, outcome: "stopped", exit_status: nil)
      @mutex.synchronize { @children.delete(env_id) }
    end

    stopped_ids = stopped_children.keys
    with_connection do
      PreviewEnvironment.where(id: stopped_ids, state: "stopping").find_each do |env|
        env.mark_stopped! && env.save!
        PreviewWorkspace.cleanup_for(env)
      end
    end

    Rails.logger.info("[PreviewService] shutdown complete")
  end
end
