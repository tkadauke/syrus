require "fileutils"

module SyrusSidecarBootstrap
  BUNDLE_ENV_KEYS = %w[BUNDLE_APP_CONFIG BUNDLE_USER_HOME BUNDLE_USER_CACHE BUNDLE_BIN_PATH RUBYOPT].freeze
  SECRET_ENV_FILE_PATHS = %w[
    /run/syrus/sidecar.env
    /run/secrets/syrus_sidecar_env
  ].freeze
  ISO_TIME_FORMAT = "%Y-%m-%dT%H:%M:%SZ"

  module_function

  def prepare_bundle!(sidecar_env_key:)
    load_secret_env_file!
    ENV["BUNDLE_GEMFILE"] = File.expand_path("../Gemfile", __dir__)
    ENV[sidecar_env_key] = "1" if sidecar_env_key.to_s != ""
    ENV.delete("SYRUS_ROLE")
    BUNDLE_ENV_KEYS.each { |key| ENV.delete(key) }
  end

  def load_secret_env_file!
    path = SECRET_ENV_FILE_PATHS.find { |candidate| File.file?(candidate) }
    return unless path

    File.foreach(path) do |line|
      key, value = parse_env_line(line)
      ENV[key] = value if key
    end
  rescue StandardError => e
    warn "[syrus-sidecar-bootstrap] failed to load sidecar env file: #{e.class}: #{e.message}"
  end

  def parse_env_line(line)
    stripped = line.to_s.strip
    return nil if stripped.empty? || stripped.start_with?("#")

    key, value = stripped.split("=", 2)
    return nil unless key&.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/) && !value.nil?

    [ key, unquote_env_value(value) ]
  end

  def unquote_env_value(value)
    value = value.strip
    if value.length >= 2 && value.start_with?('"') && value.end_with?('"')
      value[1...-1].gsub('\n', "\n").gsub('\"', '"').gsub("\\\\", "\\")
    elsif value.length >= 2 && value.start_with?("'") && value.end_with?("'")
      value[1...-1]
    else
      value
    end
  end

  def open_run_stderr!(run_id:, server_name:)
    run_id = run_id.to_s
    return unless numeric?(run_id)

    open_stderr!(
      env_key: "SYRUS_MCP_SIDECAR_STDERR_LOG",
      filename: "run-#{run_id}.stderr.log",
      startup_line: "[#{timestamp}] starting #{server_name} pid=#{Process.pid} run_id=#{run_id}",
      warning_prefix: server_name
    )
  end

  def open_chat_stderr!(chat_session_id:, message_id:, server_name:)
    chat_session_id = chat_session_id.to_s
    message_id = message_id.to_s
    return unless numeric?(chat_session_id) && numeric?(message_id)

    open_stderr!(
      env_key: "SYRUS_CHAT_MCP_SIDECAR_STDERR_LOG",
      filename: "chat-#{chat_session_id}-message-#{message_id}-#{safe_filename(server_name)}.stderr.log",
      startup_line: "[#{timestamp}] starting #{server_name} pid=#{Process.pid} chat_session_id=#{chat_session_id} message_id=#{message_id}",
      warning_prefix: server_name
    )
  end

  def data_root
    ENV["SYRUS_DATA_ROOT"].to_s.empty? ? File.expand_path("~/.syrus") : ENV["SYRUS_DATA_ROOT"]
  end

  def safe_filename(value)
    sanitized = value.to_s.gsub(/[^A-Za-z0-9_.-]/, "_")
    sanitized.empty? ? "unknown" : sanitized
  end

  def numeric?(value)
    value.to_s.match?(/\A\d+\z/)
  end

  def timestamp
    Time.now.utc.strftime(ISO_TIME_FORMAT)
  end

  def open_stderr!(env_key:, filename:, startup_line:, warning_prefix:)
    log_dir = File.join(data_root, "mcp-sidecar-logs")
    FileUtils.mkdir_p(log_dir)
    stderr_path = File.join(log_dir, filename)
    ENV[env_key] = stderr_path
    STDERR.reopen(stderr_path, "w")
    STDERR.sync = true
    warn startup_line
  rescue StandardError => e
    warn "[#{warning_prefix}] failed to open stderr log: #{e.class}: #{e.message}"
  end
end
