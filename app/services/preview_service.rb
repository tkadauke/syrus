require "net/http"

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

  POLL_INTERVAL_SECONDS = 2
  TTL_CHECK_INTERVAL_SECONDS = 30
  HEALTH_CHECK_TIMEOUT_SECONDS = 120
  HEALTH_CHECK_RETRY_INTERVAL_SECONDS = 2
  GRACEFUL_SHUTDOWN_TIMEOUT_SECONDS = 10

  ChildProcess = Struct.new(:pid, :environment_id, :port, keyword_init: true)

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
        check_ttl_expirations if ttl_check_due?
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
      with_connection { mark_failed(env, e.message) }
    end
  end

  def start_environment(env)
    port = allocate_port
    unless port
      Rails.logger.warn("[PreviewService] no free port available for environment #{env.id}")
      return
    end

    workspace_path = env.workspace_path
    unless workspace_path && Dir.exist?(workspace_path)
      Rails.logger.warn("[PreviewService] no usable workspace for environment #{env.id}")
      return
    end

    source = PreviewCommandSource.new(workspace_path).resolve
    unless source
      mark_failed(env, "no preview command configured for this repository")
      return
    end

    env.update_columns(port: port, internal_host: "127.0.0.1")
    env.begin_seeding! && env.save!

    run_seed_command(source, workspace_path) if source.seed_command

    pid = spawn_app(source.start_command_for.call(port: port), workspace_path, port)
    @mutex.synchronize { @children[env.id] = ChildProcess.new(pid: pid, environment_id: env.id, port: port) }

    await_health_check(env, port, source.health_check_path)
  end

  def run_seed_command(source, workspace_path)
    Rails.logger.info("[PreviewService] running seed: #{source.seed_command}")
    result = system(source.seed_command, chdir: workspace_path, exception: false)
    Rails.logger.warn("[PreviewService] seed command exited non-zero") unless result
  end

  def spawn_app(command, workspace_path, port)
    env = { "PORT" => port.to_s }
    pid = Process.spawn(env, command, chdir: workspace_path, pgroup: true,
                                      out: "/dev/null", err: "/dev/null")
    Rails.logger.info("[PreviewService] spawned pid=#{pid} port=#{port} cmd=#{command.inspect}")
    pid
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

      if http_ok?("http://127.0.0.1:#{port}#{health_check_path}")
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

      with_connection do
        env = PreviewEnvironment.find_by(id: env_id)
        next unless env

        if env.stopping?
          env.mark_stopped! && env.save!
          Rails.logger.info("[PreviewService] environment #{env_id} stopped (pid=#{child.pid})")
        elsif exit_status.success?
          env.begin_stopping! && env.save!
          env.mark_stopped! && env.save!
          Rails.logger.info("[PreviewService] environment #{env_id} exited cleanly")
        else
          mark_failed(env, "process exited unexpectedly with status #{exit_status.exitstatus}")
        end
      end
    end
  end

  def stop_environment(env)
    child = @mutex.synchronize { @children[env.id] }
    env.begin_stopping! && env.save!

    if child
      kill_process_group(child.pid)
    else
      env.mark_stopped! && env.save!
    end
  end

  def kill_process_group(pid)
    Process.kill("-TERM", pid)
  rescue Errno::ESRCH, Errno::EPERM
    # Already gone.
  end

  def mark_failed(env, message)
    env.update_columns(error_message: message) if env.persisted?
    env.fail! && env.save! if env.may_fail?
    Rails.logger.error("[PreviewService] environment #{env.id} failed: #{message}")
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
    @mutex.synchronize { @children.dup }.each do |env_id, child|
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
      @mutex.synchronize { @children.delete(env_id) }
    end

    remaining_ids = @mutex.synchronize { @children.keys }
    with_connection do
      PreviewEnvironment.where(id: remaining_ids, state: "stopping").find_each do |env|
        env.mark_stopped! && env.save!
      end
    end

    Rails.logger.info("[PreviewService] shutdown complete")
  end
end
