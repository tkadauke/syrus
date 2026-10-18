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
  PREVIEW_COMMAND_TIMEOUT_SECONDS = 10.minutes.to_i
  GRACEFUL_SHUTDOWN_TIMEOUT_SECONDS = 10
  ChildProcess = Struct.new(:pid, :environment_id, :port, :spawned_process_id, :handle, keyword_init: true) do
    def managed_handle
      handle || ProcessRunner::BackgroundHandle.find(spawned_process_id)
    end
  end

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
    with_connection { restore_managed_children! }

    loop do
      break if @shutting_down

      with_connection do
        poll_starting_environments
        poll_stopping_environments
        check_ttl_expirations if ttl_check_due?
        reconcile_finished_children!
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

    source = PreviewCommandSource.new(workspace_path, project_id: env.project_id).resolve
    unless source
      mark_failed(env, "no preview command configured for this repository")
      return
    end
    workdir = preview_workdir(env, workspace_path)

    port = allocate_port
    unless port
      mark_failed(env, "no free preview port available")
      return
    end

    env.update_columns(port: port, internal_host: INTERNAL_HOST)
    env.begin_seeding! && env.save!

    process_env = preview_process_env(source, workdir, preview_key: env.id)

    return unless run_setup_commands(source, workdir, workspace_path, env, process_env)
    return if stop_requested?(env)

    return if source.seed_command && !run_seed_command(source, workdir, workspace_path, env, process_env)
    return if stop_requested?(env)

    child = spawn_app(source.start_command_for.call(port: port), workdir, port, env, process_env)
    @mutex.synchronize { @children[env.id] = child }

    await_health_check(env, port, source.health_check_path)
  end

  def run_seed_command(source, workdir, workspace_path, env, process_env)
    run_preview_command!("seed", source.seed_command, workdir, workspace_path, env, process_env)
  end

  def run_setup_commands(source, workdir, workspace_path, env, process_env)
    Array(source.setup_commands).each do |command|
      return false unless run_preview_command!("setup", command, workdir, workspace_path, env, process_env)
    end
    true
  end

  def run_preview_command!(label, command, workdir, workspace_path, env, process_env)
    Rails.logger.info("[PreviewService] running #{label}: #{command}")
    result = ProcessRunner.new(
      env: process_env,
      command: [ "bash", "-c", command ],
      mounts: ProcessRunner.mounts(workdir, read_write: workspace_path),
      network: "prepare",
      timeout: PREVIEW_COMMAND_TIMEOUT_SECONDS,
      kind: "preview",
      job: env.job,
      display_command: command,
      stop_requested: -> { preview_command_stop_requested?(env) }
    ).run
    return true if result.success?

    if result.stopped? || result.operator_killed?
      stop_environment(env)
      return false
    end

    suffix = if result.timed_out?
      " timed out after #{PREVIEW_COMMAND_TIMEOUT_SECONDS}s"
    else
      " exited non-zero"
    end
    raise "preview #{label} command#{suffix}: #{command}"
  end

  def preview_command_stop_requested?(env)
    return true if @shutting_down

    env.reload.stopping?
  end

  def preview_workdir(env, workspace_path)
    return workspace_path if env.project_id.blank?

    project = TargetGraph::Compiler.compile(workspace_path).project(env.project_id)
    return workspace_path unless project&.path.present?

    File.join(workspace_path, project.path)
  rescue StandardError => e
    Rails.logger.warn("[PreviewService] could not resolve preview project #{env.project_id.inspect}: #{e.class}: #{e.message}")
    workspace_path
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
    handle = ProcessRunner.new(
      env: env, command: [ "bash", "-c", command ],
      mounts: ProcessRunner.mounts(workspace_path), network: "prepare",
      timeout: 24.hours, kind: "preview", job: preview_environment.job,
      display_command: command,
      resource_attribution: {
        preview_environment_id: preview_environment.id,
        job_id: preview_environment.job_id,
        repository_id: preview_environment.repository_id,
        port: port
      }
    ).start
    spawned_process = handle.spawned_process
    Rails.logger.info("[PreviewService] spawned pid=#{spawned_process.pid} port=#{port} cmd=#{command.inspect}")
    ChildProcess.new(pid: handle.pid, environment_id: preview_environment.id, port: port,
      spawned_process_id: handle.spawned_process_id, handle: handle)
  end

  def preview_process_env(source, workspace_path, preview_key: nil)
    env = ProcessRunner.forwarded_env(
      Steps::Prepare.prep_env_forward,
      extra: WorkspaceDependencyEnv.for(workspace_path)
    )
    Array(source.unset_env).each { |name| env[name.to_s] = nil }
    env.merge!(source.environment(key: preview_key))
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

  def reconcile_finished_children!
    @mutex.synchronize { @children.dup }.each do |env_id, child|
      process = SpawnedProcess.find_by(id: child.spawned_process_id)
      next if process && !process.finished?

      @mutex.synchronize { @children.delete(env_id) }
      with_connection do
        env = PreviewEnvironment.find_by(id: env_id)
        next unless env

        if env.stopping? || process&.outcome == "operator_killed"
          env.begin_stopping! && env.save! if env.may_begin_stopping?
          env.mark_stopped! && env.save!
          cleanup_preview_database(env)
          PreviewWorkspace.cleanup_for(env)
          Rails.logger.info("[PreviewService] environment #{env_id} stopped (pid=#{child.pid})")
        elsif process&.outcome == "succeeded"
          env.begin_stopping! && env.save!
          env.mark_stopped! && env.save!
          cleanup_preview_database(env)
          PreviewWorkspace.cleanup_for(env)
          Rails.logger.info("[PreviewService] environment #{env_id} exited cleanly")
        else
          outcome = process&.outcome || "missing process record"
          mark_failed(env, "preview process ended unexpectedly (#{outcome})")
        end
      end
    end
  end

  def stop_environment(env)
    child = @mutex.synchronize { @children[env.id] }
    env.begin_stopping! && env.save! if env.may_begin_stopping?

    if child
      child.managed_handle.cancel!
    else
      env.mark_stopped! && env.save!
      cleanup_preview_database(env)
      PreviewWorkspace.cleanup_for(env)
    end
  end

  def mark_failed(env, message, reason: nil)
    child = @mutex.synchronize { @children.delete(env.id) }
    child&.managed_handle&.cancel!

    env.update_columns(error_message: message, error_reason: reason) if env.persisted?
    env.fail! && env.save! if env.may_fail?
    cleanup_preview_database(env)
    PreviewWorkspace.cleanup_for(env)
    Rails.logger.error("[PreviewService] environment #{env.id} failed: #{message}")
  end

  def cleanup_preview_database(env)
    workspace_path = env.workspace_path
    return unless workspace_path.present? && Dir.exist?(workspace_path)

    workdir = preview_workdir(env, workspace_path)
    source = PreviewCommandSource.new(workspace_path, project_id: env.project_id).resolve
    return if source&.cleanup_command.blank?

    result = ProcessRunner.new(
      env: preview_process_env(source, workdir, preview_key: env.id),
      command: [ "bash", "-c", source.cleanup_command ],
      mounts: ProcessRunner.mounts(workdir, read_write: workspace_path),
      network: "prepare",
      timeout: PREVIEW_COMMAND_TIMEOUT_SECONDS,
      kind: "preview",
      job: env.job,
      display_command: source.cleanup_command
    ).run
    Rails.logger.warn("[PreviewService] database cleanup failed for environment #{env.id}") unless result.success?
  rescue StandardError => e
    Rails.logger.warn("[PreviewService] database cleanup failed for environment #{env.id}: #{CommandRedactor.redact(e.message)}")
  end

  def child_exited?(child)
    return false unless child.spawned_process_id

    child.managed_handle.finished?
  rescue ActiveRecord::RecordNotFound
    true
  end

  def allocate_port
    used = @mutex.synchronize { @children.values.map(&:port).to_set }
    used += PreviewEnvironment.where(state: PreviewEnvironment::ACTIVE_STATES)
                              .where.not(port: nil)
                              .pluck(:port).to_set
    candidates = (PORT_MIN..PORT_MAX).to_a.shuffle
    candidates.find { |p| !used.include?(p) && !self.class.port_in_use?(p) }
  end

  # Reattach durable handles after the service process restarts. The runner
  # (or the orphan reaper when its owning worker disappeared) remains the
  # authority for the subprocess outcome; PreviewService only reconciles that
  # outcome into the environment state machine.
  def restore_managed_children!
    active = PreviewEnvironment.where(state: PreviewEnvironment::ACTIVE_STATES).index_by(&:id)
    return if active.empty?

    SpawnedProcess.where(kind: "preview").find_each(order: :asc) do |process|
      environment_id = process.resource_attribution["preview_environment_id"]
      env = active[environment_id]
      next unless env && process.pid

      @children[env.id] = ChildProcess.new(
        pid: process.pid,
        environment_id: env.id,
        port: env.port,
        spawned_process_id: process.id,
        handle: ProcessRunner::BackgroundHandle.find(process.id)
      )
    end
  end

  def shutdown_gracefully
    Rails.logger.info("[PreviewService] shutting down, stopping #{@children.size} child(ren)")

    with_connection do
      PreviewEnvironment.where(id: @children.keys).each do |env|
        env.begin_stopping! && env.save! if env.may_begin_stopping?
      end
    end

    @mutex.synchronize { @children.dup }.each do |_env_id, child|
      child.managed_handle.cancel!
    end

    deadline = Time.current + GRACEFUL_SHUTDOWN_TIMEOUT_SECONDS
    stopped_children = @mutex.synchronize { @children.dup }
    stopped_children.each do |env_id, child|
      remaining = [ deadline - Time.current, 0 ].max
      begin
        child.managed_handle.finalize(timeout: remaining)
      rescue ActiveRecord::RecordNotFound
        # Already finalized and pruned.
      end
      @mutex.synchronize { @children.delete(env_id) }
    end

    stopped_ids = stopped_children.keys
    with_connection do
      PreviewEnvironment.where(id: stopped_ids, state: "stopping").find_each do |env|
        env.mark_stopped! && env.save!
        cleanup_preview_database(env)
        PreviewWorkspace.cleanup_for(env)
      end
    end

    Rails.logger.info("[PreviewService] shutdown complete")
  end
end
