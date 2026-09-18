require "fileutils"
require "json"
require "securerandom"
require "set"

class MuseInvocation
  DEFAULT_TIMEOUT_SECONDS = AgentInvocation::DEFAULT_TIMEOUT_SECONDS
  DEFAULT_TRANSCRIPT_POLICY = :redacted_export
  TRANSCRIPT_POLICIES = %i[redacted_export raw_export exec_jsonl].freeze
  STARTUP_ERROR_MAX_BYTES = 4.kilobytes
  # The image pins the launcher with MUSE_NO_AUTO_UPDATE (see Dockerfile), but
  # AgentInvocation::ENV_FORWARD does not carry it, so every scrubbed invocation
  # would otherwise re-enable the launcher's update check -- which stalls startup
  # and fails writing its timestamp into the read-only /opt/muse/bin.
  LAUNCHER_ENV = { "MUSE_NO_AUTO_UPDATE" => "1" }.freeze
  # Muse Code's settings.json requires a top-level schema_version and, per
  # server, the documented stdio shape (transport/command/args/env) plus
  # enabled/mode -- confirmed against the installed `muse` binary's
  # `SessionMcpServerConfig`/`SessionMcpServerMode` wire schema
  # (`muse schema generate-json-schema`). "required" makes Muse hard-fail
  # startup instead of silently dropping the sidecar when it can't connect.
  SETTINGS_SCHEMA_VERSION = 1
  REQUIRED_SERVER_MODE = "required"

  def initialize(workspace_path, prompt:, api_key:,
                 log_sink: ->(*, **) { },
                 runner: nil,
                 timeout: DEFAULT_TIMEOUT_SECONDS,
                 session_id: nil,
                 model: nil,
                 reasoning_effort: nil,
                 max_model_steps: nil,
                 transcript_policy: DEFAULT_TRANSCRIPT_POLICY,
                 transcript_dir: nil,
                 muse_home: nil,
                 mcp_server: nil,
                 required_mcp_tools: nil,
                 stop_requested: -> { false },
                 process_started: ->(_process) { })
    @workspace_path = workspace_path.to_s
    @prompt = prompt.to_s
    @api_key = api_key.to_s
    @log_sink = log_sink
    @runner = runner || method(:default_runner)
    @timeout = timeout
    @session_id = session_id.presence || SecureRandom.uuid
    @model = model.to_s.strip.presence
    @reasoning_effort = reasoning_effort.to_s.strip.presence
    @max_model_steps = max_model_steps
    @transcript_policy = normalize_transcript_policy(transcript_policy)
    @transcript_dir = transcript_dir&.to_s
    @muse_home = muse_home&.to_s
    @mcp_server = mcp_server
    @required_mcp_tools = Array(required_mcp_tools).compact_blank.map(&:to_s)
    @stop_requested = stop_requested
    @process_started = process_started
  end

  attr_reader :session_id

  def run
    @runner.call(
      workspace_path: @workspace_path,
      prompt: @prompt,
      api_key: @api_key,
      log_sink: @log_sink,
      timeout: @timeout,
      session_id: @session_id,
      model: @model,
      reasoning_effort: @reasoning_effort,
      max_model_steps: @max_model_steps,
      transcript_policy: @transcript_policy,
      transcript_dir: @transcript_dir,
      stop_requested: @stop_requested,
      process_started: @process_started
    )
  end

  private

  def default_runner(workspace_path:, prompt:, api_key:, log_sink:, timeout:,
                     session_id:, model: nil, reasoning_effort: nil, max_model_steps: nil,
                     transcript_policy: DEFAULT_TRANSCRIPT_POLICY, transcript_dir: nil,
                     stop_requested: -> { false }, process_started: ->(_process) { })
    exec_jsonl = +""
    metadata = default_metadata(session_id)
    @metadata = metadata
    @required_mcp_failed = false
    @required_mcp_failure_logged = false

    Dir.mktmpdir("syrus-muse-invocation-") do |tmpdir|
      prompt_path = File.join(tmpdir, "prompt.txt")
      File.write(prompt_path, prompt)
      write_muse_settings!(muse_home: @muse_home, mcp_server: @mcp_server, log_sink: log_sink)

      runner_result = ProcessRunner.new(
        env: muse_env(workspace_path, muse_home: @muse_home),
        command: muse_exec_command(
          workspace_path: workspace_path,
          prompt_path: prompt_path,
          session_id: session_id,
          model: model,
          reasoning_effort: reasoning_effort,
          max_model_steps: max_model_steps
        ),
        stdin_data: api_key,
        chdir: workspace_path,
        timeout: timeout,
        silent_timeout: AgentInvocation::SILENT_TIMEOUT_SECONDS,
        kind: "agent",
        run: current_run,
        workflow: current_run&.workflow,
        chat_session: current_chat_session,
        agent: current_agent,
        stop_requested: -> { stop_requested.call || @required_mcp_failed },
        on_spawned_process: process_started,
        on_output_line: ->(line) do
          exec_jsonl << line
          exec_jsonl << "\n" unless line.end_with?("\n")
          update = process_event(line, log_sink)
          metadata.merge!(update.compact) if update
        end
      ).run

      apply_missing_terminal_failure!(metadata, runner_result) if metadata[:outcome].blank?
      apply_required_mcp_failure!(metadata, log_sink)
      cleanup_timeout = cleanup_timeout?(metadata, runner_result)
      transcript = capture_transcript(
        workspace_path: workspace_path,
        session_id: session_id,
        policy: transcript_policy,
        transcript_dir: transcript_dir || tmpdir,
        exec_jsonl: exec_jsonl,
        log_sink: log_sink,
        stop_requested: -> { stop_requested.call || @required_mcp_failed }
      )

      AgentInvocation::Result.new(
        turns: metadata[:turns],
        exit_status: cleanup_timeout ? 0 : runner_result.exit_status,
        timed_out: !cleanup_timeout && (runner_result.timed_out || runner_result.silent_timed_out),
        is_error: metadata[:is_error],
        outcome: metadata[:outcome],
        final_text: metadata[:final_text],
        session_id: metadata[:session_id],
        transcript_path: transcript[:path],
        transcript_jsonl: transcript[:jsonl],
        input_tokens: metadata[:input_tokens],
        output_tokens: metadata[:output_tokens],
        cache_creation_input_tokens: metadata[:cache_creation_input_tokens],
        cache_read_input_tokens: metadata[:cache_read_input_tokens],
        process_outcome: process_outcome(runner_result),
        spawned_process_id: runner_result.spawned_process_id,
        silent_timed_out: !cleanup_timeout && runner_result.silent_timed_out,
        stopped: runner_result.stopped,
        operator_killed: runner_result.operator_killed,
        aliveness_failed: runner_result.aliveness_failed
      )
    end
  rescue Errno::ENOENT => e
    process_start_failure(e)
  end

  def default_metadata(session_id)
    {
      turns: nil,
      is_error: false,
      outcome: nil,
      final_text: nil,
      session_id: session_id,
      input_tokens: nil,
      output_tokens: nil,
      cache_creation_input_tokens: nil,
      cache_read_input_tokens: nil,
      startup_output: nil
    }
  end

  def muse_env(workspace_path, muse_home: nil)
    env = ProcessRunner.forwarded_env(
      AgentInvocation::ENV_FORWARD,
      extra: LAUNCHER_ENV.merge(WorkspaceDependencyEnv.for(workspace_path))
    )
    if muse_home.present?
      env["HOME"] = muse_home
      env["XDG_CONFIG_HOME"] = File.join(muse_home, ".config")
    end
    env
  end

  def write_muse_settings!(muse_home:, mcp_server:, log_sink:)
    return if muse_home.blank? || mcp_server.blank?

    config_dir = File.join(muse_home, ".config", "muse")
    FileUtils.mkdir_p(config_dir)
    settings_path = File.join(config_dir, "settings.json")
    settings = read_existing_muse_settings(settings_path)
    settings["schema_version"] = SETTINGS_SCHEMA_VERSION
    settings["mcp_servers"] = settings.fetch("mcp_servers", {}).merge(normalized_mcp_servers(mcp_server))
    File.write(settings_path, JSON.pretty_generate(settings))
    log_sink.call(
      "[mcp_config] server=syrus-mcp-sidecar config=#{settings_path}",
      kind: "system"
    )
  end

  def read_existing_muse_settings(settings_path)
    return {} unless File.exist?(settings_path)

    parsed = JSON.parse(File.read(settings_path))
    parsed.is_a?(Hash) ? parsed : {}
  rescue JSON::ParserError
    {}
  end

  # Normalizes into Muse's documented per-server stdio shape regardless of
  # what the caller supplied (agent_providers/muse.rb's mcp_server only sets
  # command/args/env), so schema_version/transport/enabled/mode are always
  # present without requiring every caller to know Muse's exact contract.
  def normalized_mcp_servers(mcp_server)
    mcp_server.transform_values do |server|
      server = server.stringify_keys
      {
        "transport" => "stdio",
        "command" => server["command"],
        "args" => Array(server["args"]),
        "env" => server["env"] || {},
        "enabled" => true,
        "mode" => REQUIRED_SERVER_MODE
      }
    end
  end

  def required_mcp_state(metadata)
    metadata[:required_mcp_state] ||= { servers: [], tools: Set.new, called: Set.new, saw_inventory: false }
  end

  def muse_exec_command(workspace_path:, prompt_path:, session_id:, model:, reasoning_effort:, max_model_steps:)
    [
      "muse", "exec",
      "--json",
      "--provider", "meta",
      "--workspace", workspace_path,
      "--approval-mode", "never",
      "--user-input-auto-resolve",
      "--session-id", session_id,
      "--prompt-file", prompt_path,
      "--api-key-stdin",
      *optional_flag("--model", model),
      *optional_flag("--reasoning-effort", reasoning_effort),
      *positive_integer_flag("--max-model-steps", max_model_steps)
    ]
  end

  def optional_flag(name, value)
    return [] if value.blank?

    [ name, value.to_s ]
  end

  def positive_integer_flag(name, value)
    value = value.to_i if value.respond_to?(:to_i)
    return [] unless value.respond_to?(:positive?) && value.positive?

    [ name, value.to_s ]
  end

  def process_event(line, log_sink)
    event = JSON.parse(line.strip)
    return malformed_startup_output(line, log_sink) unless event.is_a?(Hash)

    payload_type = event["payload_type"].presence || event["type"].presence
    payload = event["payload"].is_a?(Hash) ? event["payload"] : {}

    case payload_type
    when "mcp.init", "mcp.tools", "tools.available", "tool.inventory"
      process_mcp_inventory(payload, log_sink)
    when "tool.call", "tool_call", "tool.use", "mcp.tool_call", "mcp.tool.call", "msp.tool_call", "msp.tool.call"
      process_tool_call(payload, log_sink)
    when "tool.result", "tool_result", "tool.output", "mcp.tool_result", "mcp.tool.result", "msp.tool_result", "msp.tool.result"
      process_tool_result(payload, log_sink)
    when "session.created", "run.session.created", "run.started"
      session = payload["session_id"].presence || payload["session"].presence
      session ? { session_id: session } : nil
    when "turn.input.user"
      nil
    when "run.output.delta", "run.output.text", "assistant.message", "assistant.text", "message.assistant"
      text = payload_text(payload)
      log_sink.call(text, kind: "assistant_text") if text.present?
      text.present? ? { final_text: text } : nil
    when "task.lifecycle.failed"
      detail = sanitized_event_detail(payload, fallback: "Muse task lifecycle failed.")
      log_sink.call("[muse diagnostic] #{detail}", kind: "system")
      nil
    when "run.terminal.completed"
      log_terminal_result(payload, log_sink)
      {
        turns: payload["turns"] || payload["num_turns"],
        is_error: false,
        outcome: payload["outcome"].presence || payload["status"].presence || "success",
        final_text: payload_text(payload),
        session_id: payload["session_id"]
      }.merge(usage_updates(payload))
    when "run.terminal.failed", "run.terminal.error"
      detail = sanitized_event_detail(payload, fallback: "Muse run failed.")
      log_sink.call("[muse error] #{detail}", kind: "system")
      classified_failure(detail, payload: payload)
    else
      nil
    end
  rescue JSON::ParserError
    malformed_startup_output(line, log_sink)
  end

  def process_mcp_inventory(payload, log_sink)
    state = required_mcp_state(@metadata ||= {})
    tools = Array(payload["tools"] || payload["available_tools"] || payload["tool_names"]).filter_map do |tool|
      tool.is_a?(Hash) ? qualified_tool_name(tool, tool["name"].presence || tool["tool"].presence || tool["tool_name"].presence) : tool.to_s.presence
    end
    servers = Array(payload["servers"] || payload["mcp_servers"]).filter_map do |server|
      next unless server.is_a?(Hash)

      { "name" => server["name"].to_s, "status" => server["status"].to_s.presence || "unknown" }
    end
    state[:saw_inventory] = true
    state[:tools].merge(tools)
    state[:servers] = servers if servers.present?
    log_sink.call(
      "[mcp_tools_init] count=#{tools.count { |tool| mcp_tool_name?(tool) }} required=#{@required_mcp_tools.join(',')} tools=#{tools.select { |tool| mcp_tool_name?(tool) }.join(',')}",
      kind: "system"
    )
    log_sink.call(
      "[mcp_servers] #{servers.map { |s| "#{s['name']}=#{s['status']}" }.join(', ')}",
      kind: "system",
      mcp_servers: servers
    ) if servers.present?
    required_mcp_tools_update(log_sink)
  end

  def process_tool_call(payload, log_sink)
    name = payload["name"].presence || payload["tool"].presence || payload["tool_name"].presence
    name = qualified_tool_name(payload, name)
    required_mcp_state(@metadata ||= {})[:called] << name if name.present?
    log_sink.call(
      AgentEventAbbreviator.tool_use(name, tool_input(payload), path_roots: [ @workspace_path ]),
      kind: "tool_call",
      tool_name: name,
      tool_input: tool_input(payload),
      tool_use_id: tool_id(payload)
    ) if name.present?
    required_mcp_tools_update(log_sink)
  end

  def process_tool_result(payload, log_sink)
    name = payload["name"].presence || payload["tool"].presence || payload["tool_name"].presence
    name = qualified_tool_name(payload, name)
    log_sink.call(
      AgentEventAbbreviator.tool_result(tool_result_content(payload), error: payload_error?(payload)),
      kind: "tool_result",
      tool_name: name,
      tool_result_content: tool_result_content(payload),
      tool_result_error: payload_error?(payload),
      tool_use_id: tool_id(payload)
    )
    nil
  end

  def required_mcp_tools_update(log_sink)
    return if @required_mcp_tools.empty?

    state = required_mcp_state(@metadata ||= {})
    return if required_tools_satisfied?(state[:tools]) || required_tools_satisfied?(state[:called])

    missing_tools = @required_mcp_tools.reject { |tool| mcp_tool_matches?(state[:tools], tool) || mcp_tool_matches?(state[:called], tool) }
    sidecar = state[:servers].find { |server| server["name"] == "syrus-mcp-sidecar" }
    status = sidecar&.fetch("status", nil).presence || (state[:saw_inventory] ? "missing" : nil)
    if state[:saw_inventory] && missing_tools.present?
      log_required_mcp_failure!(
        "[mcp_required] syrus-mcp-sidecar=#{status || 'missing'}; required tools missing from Muse tool inventory: #{missing_tools.join(', ')}",
        log_sink
      )
      return required_mcp_failure_update
    end

    return if status.nil? || status == "connected" || status == "pending"

    log_required_mcp_failure!(
      "[mcp_required] syrus-mcp-sidecar=#{status}; required tools unavailable: #{@required_mcp_tools.join(', ')}",
      log_sink
    )
    required_mcp_failure_update
  end

  def apply_required_mcp_failure!(metadata, log_sink)
    return if @required_mcp_tools.empty?
    state = required_mcp_state(metadata)
    return if required_tools_satisfied?(state[:tools]) || required_tools_satisfied?(state[:called])

    if metadata[:required_mcp_failed]
      metadata.merge!(required_mcp_failure_update)
      return
    end

    missing = @required_mcp_tools.reject { |tool| mcp_tool_matches?(state[:tools], tool) || mcp_tool_matches?(state[:called], tool) }
    status = state[:servers].find { |server| server["name"] == "syrus-mcp-sidecar" }&.fetch("status", nil).presence || "missing"
    detail = if state[:saw_inventory]
      "required tools missing from Muse tool inventory: #{missing.join(', ')}"
    else
      "required tools unavailable: #{missing.join(', ')}"
    end
    log_required_mcp_failure!("[mcp_required] syrus-mcp-sidecar=#{status}; #{detail}", log_sink)
    metadata.merge!(required_mcp_failure_update)
  end

  def log_required_mcp_failure!(message, log_sink)
    @required_mcp_failed = true
    return if @required_mcp_failure_logged

    log_sink.call(message, kind: "system")
    @required_mcp_failure_logged = true
  end

  def required_mcp_failure_update
    {
      required_mcp_failed: true,
      is_error: true,
      outcome: "mcp_sidecar_failed",
      final_text: nil
    }
  end

  def required_tools_satisfied?(tools)
    @required_mcp_tools.all? { |tool| mcp_tool_matches?(tools, tool) }
  end

  def mcp_tool_matches?(available_tools, required_tool)
    Array(available_tools).any? do |name|
      name.to_s == required_tool ||
        name.to_s.end_with?("__#{required_tool}") ||
        name.to_s.end_with?(".#{required_tool}")
    end
  end

  def mcp_tool_name?(tool_name)
    name = tool_name.to_s
    name.start_with?("mcp__") || name.include?(".")
  end

  def qualified_tool_name(payload, name)
    server = payload["server"].presence || payload["server_name"].presence
    tool = name.to_s
    return nil if tool.blank?
    return tool if server.blank? || tool.start_with?("mcp__") || tool.include?(".")

    "#{server}.#{tool}"
  end

  def malformed_startup_output(line, log_sink)
    detail = sanitize(line.chomp)
    log_sink.call(detail) if detail.present?
    detail.present? ? { startup_output: detail } : nil
  end

  def payload_text(payload)
    value = payload["delta"].presence ||
      payload["final_text"].presence ||
      payload["result"].presence ||
      payload["text"].presence ||
      payload["message"].presence ||
      payload["output"].presence ||
      payload["content"].presence

    return value if value.is_a?(String)
    return value.map { |part| content_text(part) }.compact_blank.join("\n") if value.is_a?(Array)

    value.to_json if value.is_a?(Hash)
  end

  def content_text(part)
    return part if part.is_a?(String)
    return unless part.is_a?(Hash)

    part["text"].presence || part["content"].presence || part["delta"].presence
  end

  def tool_input(payload)
    value = payload["input"] || payload["arguments"] || payload["args"]
    return {} if value.blank?
    return JSON.parse(value) if value.is_a?(String) && value.strip.start_with?("{")

    value
  rescue JSON::ParserError
    value
  end

  def tool_id(payload)
    payload["id"] || payload["tool_use_id"] || payload["call_id"] || payload["invocation_id"]
  end

  def tool_result_content(payload)
    payload["content"] || payload["result"] || payload["output"] || payload["data"]
  end

  def payload_error?(payload)
    payload["error"].present? || payload["is_error"] == true || payload["status"].to_s == "error"
  end

  def usage_updates(payload)
    usage = payload["usage"].is_a?(Hash) ? payload["usage"] : payload
    {
      input_tokens: usage["input_tokens"],
      output_tokens: usage["output_tokens"],
      cache_creation_input_tokens: usage["cache_creation_input_tokens"],
      cache_read_input_tokens: usage["cache_read_input_tokens"] || usage["cached_input_tokens"]
    }
  end

  def log_terminal_result(payload, log_sink)
    usage = usage_updates(payload)
    log_sink.call(
      "[muse result] outcome=#{payload['outcome'].presence || payload['status'].presence || 'success'}, turns=#{payload['turns'] || payload['num_turns']}, input_tokens=#{usage[:input_tokens]}, output_tokens=#{usage[:output_tokens]}",
      kind: "system"
    )
  end

  def sanitized_event_detail(payload, fallback:)
    sanitize(
      payload["error"].presence ||
        payload["message"].presence ||
        payload["detail"].presence ||
        payload_text(payload).presence ||
        fallback
    )
  end

  def classified_failure(detail, payload: {})
    if muse_usage_limit?(detail, payload)
      { is_error: true, outcome: ProviderUsageLimit::OUTCOME, final_text: detail }
    elsif muse_auth_failure?(detail, payload)
      { is_error: true, outcome: ProviderAuthFailure::OUTCOME, final_text: detail }
    else
      { is_error: true, outcome: "run_failed", final_text: detail }
    end
  end

  def muse_usage_limit?(detail, payload)
    ProviderUsageLimit.detect?(detail) ||
      payload["error_type"].to_s.match?(/usage|quota|billing|credit/i) ||
      payload["code"].to_s.match?(/usage|quota|billing|credit/i)
  end

  def muse_auth_failure?(detail, payload)
    ProviderAuthFailure.detect?(detail) ||
      detail.match?(/\b(?:invalid|expired|missing)\s+(?:api\s+)?key\b/i) ||
      payload["error_type"].to_s.match?(/auth|unauthori[sz]ed|credential/i) ||
      payload["code"].to_s.match?(/auth|unauthori[sz]ed|credential|invalid[_-]?api[_-]?key/i)
  end

  def apply_missing_terminal_failure!(metadata, runner_result)
    return if runner_result.success? && metadata[:startup_output].blank?

    detail = metadata[:startup_output].presence || process_failure_message(runner_result)
    metadata[:is_error] = true
    metadata.merge!(classified_failure(detail))
    return if metadata[:outcome].in?([ ProviderUsageLimit::OUTCOME, ProviderAuthFailure::OUTCOME ])

    metadata[:outcome] = metadata[:startup_output].present? ? "error" : process_failure_outcome(runner_result)
  end

  def cleanup_timeout?(metadata, runner_result)
    metadata[:outcome].present? && !metadata[:is_error] && (runner_result.timed_out || runner_result.silent_timed_out)
  end

  def capture_transcript(workspace_path:, session_id:, policy:, transcript_dir:, exec_jsonl:, log_sink:, stop_requested:)
    return { jsonl: exec_jsonl.presence, path: nil } if policy == :exec_jsonl
    return { jsonl: exec_jsonl.presence, path: nil } if session_id.blank?

    FileUtils.mkdir_p(transcript_dir)
    path = File.join(transcript_dir, "muse-#{session_id}-#{policy}.jsonl")
    result = ProcessRunner.new(
      env: muse_env(workspace_path, muse_home: @muse_home),
      command: muse_export_command(session_id: session_id, path: path, redacted: policy == :redacted_export),
      chdir: workspace_path,
      timeout: 60,
      silent_timeout: 15,
      kind: "agent",
      run: current_run,
      workflow: current_run&.workflow,
      chat_session: current_chat_session,
      agent: current_agent,
      stop_requested: stop_requested,
      display_command: "muse export --session #{session_id} #{policy == :redacted_export ? '--redacted ' : ''}--out #{path}"
    ).run

    if result.success? && File.exist?(path)
      { jsonl: File.read(path), path: path }
    else
      log_sink.call(
        "[muse transcript] export failed (#{process_failure_outcome(result)}); falling back to exec JSONL",
        kind: "system"
      )
      { jsonl: exec_jsonl.presence, path: nil }
    end
  rescue Errno::ENOENT
    log_sink.call(
      "[muse transcript] export command unavailable; falling back to exec JSONL",
      kind: "system"
    )
    { jsonl: exec_jsonl.presence, path: nil }
  end

  def process_start_failure(error)
    AgentInvocation::Result.new(
      turns: nil,
      exit_status: nil,
      timed_out: false,
      is_error: true,
      outcome: "process_failed",
      final_text: sanitize("Muse process failed to start: #{error.message}"),
      session_id: @session_id,
      transcript_jsonl: nil,
      transcript_path: nil,
      process_outcome: "process_failed",
      silent_timed_out: false,
      stopped: false,
      operator_killed: false,
      aliveness_failed: false
    )
  end

  def muse_export_command(session_id:, path:, redacted:)
    command = [ "muse", "export", "--session", session_id ]
    command << "--redacted" if redacted
    command + [ "--out", path ]
  end

  def process_outcome(result)
    return "succeeded" if result.success?

    process_failure_outcome(result)
  end

  def process_failure_outcome(result)
    return "operator_killed" if result.operator_killed?
    return "aliveness_failed" if result.aliveness_failed?
    return "silent_timed_out" if result.silent_timed_out?
    return "timed_out" if result.timed_out?
    return "stopped" if result.stopped?
    return "process_failed" if result.exit_status.present?

    "unknown_process_failure"
  end

  def process_failure_message(result)
    detail =
      if result.operator_killed?
        "the process was killed by an operator"
      elsif result.aliveness_failed?
        "the parent process disappeared before the runner observed a clean exit"
      elsif result.silent_timed_out?
        "the process produced no output before the silent timeout"
      elsif result.timed_out?
        "the process exceeded the wall-clock timeout"
      elsif result.stopped?
        "the process was stopped before completion"
      elsif result.exit_status
        "the process exited with status #{result.exit_status}"
      else
        "the process exited without a status"
      end

    "Muse process ended without a terminal event: #{detail}."
  end

  def normalize_transcript_policy(policy)
    normalized = policy.to_s.strip.presence&.to_sym || DEFAULT_TRANSCRIPT_POLICY
    return normalized if TRANSCRIPT_POLICIES.include?(normalized)

    raise ArgumentError, "unknown Muse transcript policy: #{policy.inspect}"
  end

  def sanitize(text)
    sanitized = text.to_s
    sanitized = sanitized.gsub(@api_key, "[redacted]") if @api_key.present?
    sanitized.safe_byteslice(0, STARTUP_ERROR_MAX_BYTES)
  end

  def current_run = Thread.current[:syrus_current_run]

  def current_chat_session = Thread.current[:syrus_current_chat_session]

  def current_agent
    Thread.current[:syrus_current_agent] ||
      (Agent.find_or_create_for!(current_run || current_chat_session) if current_run || current_chat_session)
  end
end
