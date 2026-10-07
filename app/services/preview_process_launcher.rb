require "net/http"
require "digest"
require "fileutils"
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
  class HealthCheckTimeout < StandardError; end

  HEALTH_CHECK_TIMEOUT_SECONDS = 60
  HEALTH_CHECK_INTERVAL_SECONDS = 2
  Result = Struct.new(:pid, :port, :url, :reused, :project_id, keyword_init: true)
  SpawnedPreview = Struct.new(:pid, :startup_log_path, keyword_init: true)

  def initialize(workspace_path, project_id: nil, run: nil, workflow: nil, log: nil)
    @workspace_path = workspace_path
    @project_id = project_id.presence
    @run = run
    @workflow = workflow || run&.workflow
    @log = log
  end

  def source
    @source ||= PreviewCommandSource.new(@workspace_path, project_id: @project_id).resolve
  end

  # Idempotent: returns the already-registered process under `key` rather
  # than double-spawning.
  def launch!(key:, port:, prepared: false)
    Mcp::Tools::AgentPreviewRegistry.synchronize_launch(key) do
      existing = Mcp::Tools::AgentPreviewRegistry.get(key)
      return Result.new(pid: existing[:pid], port: existing[:port], url: "http://localhost:#{existing[:port]}", reused: true, project_id: @project_id) if existing

      raise LaunchError, "no preview command configured for #{@workspace_path} — add a preview: section to .syrus.yml" unless source

      prepare! unless prepared

      command = source.start_command_for.call(port: port)
      spawned_preview = spawn_app(command, port, process_env, preview_workdir, key)
      pid = spawned_preview.pid
      Mcp::Tools::AgentPreviewRegistry.register(key: key, pid: pid, port: port)

      begin
        health_check_url = "http://127.0.0.1:#{port}#{source.health_check_path.presence || '/'}"
        await_health_check!(health_check_url)
      rescue HealthCheckTimeout => e
        Mcp::Tools::AgentPreviewRegistry.kill(key)
        raise LaunchError, timeout_message(
          command: command,
          health_check_url: health_check_url,
          startup_log_path: spawned_preview.startup_log_path,
          timeout_seconds: e.message.to_i
        )
      rescue StandardError => e
        Mcp::Tools::AgentPreviewRegistry.kill(key)
        raise LaunchError, e.message
      end

      Result.new(pid: pid, port: port, url: "http://localhost:#{port}", reused: false, project_id: @project_id)
    end
  end

  def prepare!
    PreviewPreparation.new(
      @workspace_path,
      project_id: @project_id,
      run: @run,
      workflow: @workflow,
      log: @log
    ).call
  rescue PreviewPreparation::Error => e
    raise LaunchError, e.message
  end

  private

  def spawn_app(command, port, env, workdir, key)
    spawn_env = env.merge("PORT" => port.to_s)
    startup_log_path = startup_log_path_for(key)
    FileUtils.mkdir_p(File.dirname(startup_log_path))
    File.open(startup_log_path, "w") do |startup_log|
      startup_log.sync = true
      pid = Process.spawn(spawn_env, command, chdir: workdir, pgroup: true,
                                              out: startup_log, err: startup_log,
                                              unsetenv_others: true)
      SpawnedPreview.new(pid: pid, startup_log_path: startup_log_path)
    end
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
    timeout_seconds = health_check_timeout_seconds
    deadline = Time.current + timeout_seconds
    loop do
      raise HealthCheckTimeout, timeout_seconds.to_s if Time.current > deadline
      return if http_ok?(url)
      sleep HEALTH_CHECK_INTERVAL_SECONDS
    end
  end

  def health_check_timeout_seconds
    configured_timeout = Integer(source.health_check_timeout_seconds, exception: false)
    return configured_timeout if configured_timeout&.positive?

    HEALTH_CHECK_TIMEOUT_SECONDS
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

  def timeout_message(command:, health_check_url:, startup_log_path:, timeout_seconds:)
    uri = URI.parse(health_check_url)
    parts = [
      "preview health check timed out after #{timeout_seconds}s",
      "health check: #{health_check_url} (path #{uri.request_uri})"
    ]
    parts << "project_id: #{@project_id}" if @project_id.present?
    parts << "start command: #{safe_command_summary(command)}"
    parts << "startup output: #{startup_log_path}"
    parts << configured_log_paths_summary
    parts << "Use read_preview_log for configured app logs, or inspect the startup output path above for stdout/stderr from the spawned server."

    recent_output = tail_startup_output(startup_log_path)
    parts << "recent startup output:\n#{recent_output}" if recent_output.present?

    parts.compact.join("\n")
  end

  def configured_log_paths_summary
    paths = Array(source.log_paths).compact_blank
    return "configured app logs: none" if paths.empty?

    "configured app logs: #{paths.join(', ')}"
  end

  def safe_command_summary(command)
    redacted = CommandRedactor.redact(command)
    redacted.length > 220 ? "#{redacted.first(217)}..." : redacted
  end

  def tail_startup_output(path)
    return unless File.exist?(path)

    content = File.binread(path, 4096, [ File.size(path) - 4096, 0 ].max)
    content.encode("UTF-8", invalid: :replace, undef: :replace).lines.last(40).join.strip
  rescue Errno::ENOENT
    nil
  end

  def startup_log_path_for(key)
    safe_key = key.to_s.gsub(/[^A-Za-z0-9_.-]/, "-")
    safe_key = "#{safe_key.first(48)}-#{Digest::SHA256.hexdigest(key.to_s).first(12)}" if safe_key.length > 64
    File.join(@workspace_path, ".syrus", "preview", "startup-#{safe_key}.log")
  end
end
