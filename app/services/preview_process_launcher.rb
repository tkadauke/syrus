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

  Result = Struct.new(:pid, :port, :url, :reused, :project_id, keyword_init: true)

  def initialize(workspace_path, project_id: nil)
    @workspace_path = workspace_path
    @project_id = project_id.presence
  end

  def source
    @source ||= PreviewCommandSource.new(@workspace_path, project_id: @project_id).resolve
  end

  # Idempotent: returns the already-registered process under `key` rather
  # than double-spawning.
  def launch!(key:, port:)
    existing = Mcp::Tools::AgentPreviewRegistry.get(key)
    return Result.new(pid: existing[:pid], port: existing[:port], url: "http://localhost:#{existing[:port]}", reused: true, project_id: @project_id) if existing

    raise LaunchError, "no preview command configured for #{@workspace_path} — add a preview: section to .syrus.yml" unless source

    env = process_env
    workdir = preview_workdir
    run_setup!(env, workdir)
    run_seed!(env, workdir) if source.seed_command

    command = source.start_command_for.call(port: port)
    pid = spawn_app(command, port, env, workdir)
    Mcp::Tools::AgentPreviewRegistry.register(key: key, pid: pid, port: port)

    begin
      await_health_check!("http://127.0.0.1:#{port}#{source.health_check_path.presence || '/'}")
    rescue StandardError => e
      Mcp::Tools::AgentPreviewRegistry.kill(key)
      raise LaunchError, e.message
    end

    Result.new(pid: pid, port: port, url: "http://localhost:#{port}", reused: false, project_id: @project_id)
  end

  private

  def run_setup!(env, workdir)
    Array(source.setup_commands).each { |command| run_preview_command!("setup", command, env, workdir) }
  end

  def run_seed!(env, workdir)
    run_preview_command!("seed", source.seed_command, env, workdir)
  end

  def run_preview_command!(label, command, env, workdir)
    result = system(env, "bash", "-c", command, chdir: workdir, exception: false, unsetenv_others: true)
    raise LaunchError, "preview #{label} command exited non-zero: #{command}" unless result
  end

  def spawn_app(command, port, env, workdir)
    spawn_env = env.merge("PORT" => port.to_s)
    Process.spawn(spawn_env, command, chdir: workdir, pgroup: true,
                                      out: "/dev/null", err: "/dev/null",
                                      unsetenv_others: true)
  end

  def preview_workdir
    return @workspace_path if @project_id.blank?

    project = TargetGraph::Compiler.compile(@workspace_path).project(@project_id)
    return @workspace_path unless project&.path.present?

    File.join(@workspace_path, project.path)
  rescue StandardError => e
    Rails.logger.warn("[PreviewProcessLauncher] could not resolve preview project #{@project_id.inspect}: #{e.class}: #{e.message}")
    @workspace_path
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
