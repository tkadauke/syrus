require "net/http"

# Spawns and health-checks a repo's dev server, tracking it in
# Mcp::Tools::AgentPreviewRegistry by an arbitrary caller-supplied `key`.
# Shared by Mcp::Tools::StartPreviewTool (key: a workflow Run id) and
# SyrusBrowser::RuntimeSessionProvider (key: a RuntimeSession's
# workspace_ref) so both resolve their start command through the same
# PreviewCommandSource (.syrus.yml `preview:`, or a registered
# :preview_provider plugin), spawn the same way, and poll the same health
# check before declaring the dev server ready — one implementation of
# dev-server lifecycle management, not two independently-drifting copies.
class PreviewProcessLauncher
  class LaunchError < StandardError; end

  HEALTH_CHECK_TIMEOUT_SECONDS = 60
  HEALTH_CHECK_INTERVAL_SECONDS = 2

  Result = Struct.new(:pid, :port, :url, :reused, keyword_init: true)

  def initialize(workspace_path)
    @workspace_path = workspace_path
  end

  def source
    @source ||= PreviewCommandSource.new(@workspace_path).resolve
  end

  # Idempotent: returns the already-registered process under `key` rather
  # than double-spawning.
  def launch!(key:, port:)
    existing = Mcp::Tools::AgentPreviewRegistry.get(key)
    return Result.new(pid: existing[:pid], port: existing[:port], url: "http://localhost:#{existing[:port]}", reused: true) if existing

    raise LaunchError, "no preview command configured for #{@workspace_path} — add a preview: section to .syrus.yml" unless source

    env = process_env
    run_setup!(env)
    run_seed!(env) if source.seed_command

    command = source.start_command_for.call(port: port)
    pid = spawn_app(command, port, env)
    Mcp::Tools::AgentPreviewRegistry.register(key: key, pid: pid, port: port)

    begin
      await_health_check!("http://127.0.0.1:#{port}#{source.health_check_path.presence || '/'}")
    rescue StandardError => e
      Mcp::Tools::AgentPreviewRegistry.kill(key)
      raise LaunchError, e.message
    end

    Result.new(pid: pid, port: port, url: "http://localhost:#{port}", reused: false)
  end

  private

  def run_setup!(env)
    Array(source.setup_commands).each { |command| run_preview_command!("setup", command, env) }
  end

  def run_seed!(env)
    run_preview_command!("seed", source.seed_command, env)
  end

  def run_preview_command!(label, command, env)
    result = system(env, "bash", "-c", command, chdir: @workspace_path, exception: false, unsetenv_others: true)
    raise LaunchError, "preview #{label} command exited non-zero: #{command}" unless result
  end

  def spawn_app(command, port, env)
    spawn_env = env.merge("PORT" => port.to_s)
    Process.spawn(spawn_env, command, chdir: @workspace_path, pgroup: true,
                                      out: "/dev/null", err: "/dev/null",
                                      unsetenv_others: true)
  end

  def process_env
    env = ProcessRunner.forwarded_env(
      Steps::Prepare.prep_env_forward,
      extra: WorkspaceDependencyEnv.for(@workspace_path)
    )
    Array(source.unset_env).each { |name| env[name.to_s] = nil }
    env.merge!(source.env || {})
    env
  end

  def await_health_check!(url)
    deadline = Time.current + HEALTH_CHECK_TIMEOUT_SECONDS
    loop do
      raise "preview health check timed out after #{HEALTH_CHECK_TIMEOUT_SECONDS}s" if Time.current > deadline
      return if http_ok?(url)
      sleep HEALTH_CHECK_INTERVAL_SECONDS
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
end
