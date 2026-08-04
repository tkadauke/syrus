require "fileutils"
require "json"

class CodexInvocation
  DEFAULT_TIMEOUT_SECONDS = AgentInvocation::DEFAULT_TIMEOUT_SECONDS
  DEFAULT_MODEL = "gpt-5.5"
  MCP_STARTUP_TIMEOUT_SECONDS = 60
  MCP_TOOL_TIMEOUT_SECONDS = 60

  def initialize(workspace_path, prompt:, api_key: nil,
                 log_sink: ->(*, **) { },
                 runner: nil,
                 timeout: DEFAULT_TIMEOUT_SECONDS,
                 codex_home: nil,
                 mcp_server: nil,
                 mcp_servers: nil,
                 model: nil,
                 resume_session_id: nil,
                 resume_transcript_jsonl: nil,
                 stop_requested: -> { false },
                 process_started: ->(_process) { },
                 startup_timing: nil)
    @workspace_path = workspace_path.to_s
    @prompt = prompt
    @api_key = api_key
    @log_sink = log_sink
    @runner = runner || method(:default_runner)
    @timeout = timeout
    @codex_home = codex_home&.to_s
    @mcp_server = mcp_server
    @mcp_servers = mcp_servers
    @model = model.presence || ENV.fetch("SYRUS_CODEX_MODEL", DEFAULT_MODEL).presence
    @resume_session_id = resume_session_id
    @resume_transcript_jsonl = resume_transcript_jsonl
    @stop_requested = stop_requested
    @process_started = process_started
    @startup_timing = startup_timing || StartupTiming.new(source: "codex")
  end

  def run
    @runner.call(
      workspace_path: @workspace_path,
      prompt: @prompt,
      api_key: @api_key,
      log_sink: @log_sink,
      timeout: @timeout,
      codex_home: @codex_home,
      mcp_server: @mcp_server,
      mcp_servers: @mcp_servers,
      model: @model,
      resume_session_id: @resume_session_id,
      resume_transcript_jsonl: @resume_transcript_jsonl,
      stop_requested: @stop_requested,
      process_started: @process_started,
      startup_timing: @startup_timing
    )
  end

  class StartupTiming
    def initialize(source:, sink: nil, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @source = source
      @sink = sink || ->(event) { Rails.logger.info("[codex startup] #{event}") }
      @clock = clock
      @seen = {}
    end

    def now = @clock.call

    def measure(stage, **metadata)
      started_at = now
      result = yield
      record(stage, started_at: started_at, **metadata)
      result
    end

    def record(stage, started_at:, once: false, **metadata)
      return if once && @seen[stage]

      @seen[stage] = true
      elapsed_ms = ((now - started_at) * 1000).round(1)
      fields = { source: @source, stage: stage, elapsed_ms: elapsed_ms }.merge(metadata).compact
      @sink.call(fields.map { |key, value| "#{key}=#{value.inspect}" }.join(" "))
    rescue StandardError => e
      Rails.logger.warn("[codex startup] timing sink failed: #{e.class}: #{e.message}")
    end
  end

  private

  def default_runner(workspace_path:, prompt:, api_key:, log_sink:, timeout:,
                     codex_home:, mcp_server: nil, mcp_servers: nil, model: nil,
                     resume_session_id: nil, resume_transcript_jsonl: nil,
                     stop_requested: -> { false }, process_started: ->(_process) { },
                     startup_timing: StartupTiming.new(source: "codex"))
    codex_home = codex_home.presence || File.join(Dir.home, ".codex")
    startup_timing.measure("codex_home_prepare") { FileUtils.mkdir_p(codex_home) }
    startup_timing.measure("config_write") { write_config(codex_home, mcp_servers || mcp_server, model) }
    startup_timing.measure("transcript_restore", resume: resume_session_id.present?) do
      restore_resume_transcript(codex_home, resume_session_id, resume_transcript_jsonl, log_sink)
    end

    env = codex_env(api_key: api_key, codex_home: codex_home)
    cmd = codex_command(workspace_path: workspace_path,
                        resume_session_id: resume_session_id)

    metadata = {
      turns: nil,
      is_error: false,
      outcome: nil,
      final_text: nil,
      session_id: nil,
      startup_output: nil,
      input_tokens: nil,
      output_tokens: nil,
      cache_creation_input_tokens: nil,
      cache_read_input_tokens: nil
    }
    current_run = Thread.current[:syrus_current_run]
    process_start_requested_at = startup_timing.now
    output_start_requested_at = process_start_requested_at
    mcp_server_names = normalized_mcp_servers(mcp_servers || mcp_server).keys
    runner_result = ProcessRunner.new(
      env: env,
      command: cmd,
      stdin_data: prompt,
      chdir: workspace_path,
      timeout: timeout,
      # See AgentInvocation::SILENT_TIMEOUT_SECONDS — same rationale
      # for codex: continuous JSONL streaming, prolonged silence is
      # a wedged process, not normal pacing.
      silent_timeout: AgentInvocation::SILENT_TIMEOUT_SECONDS,
      kind: "agent",
      run: current_run,
      workflow: current_run&.workflow,
      stop_requested: stop_requested,
      on_spawned_process: ->(process) {
        startup_timing.record("process_spawn", started_at: process_start_requested_at, pid: process.try(:pid))
        process_started.call(process)
      },
      on_output_line: ->(line) do
        startup_timing.record("first_agent_event", started_at: output_start_requested_at, once: true)
        if mcp_server_names.any?
          startup_timing.record(
            "mcp_startup",
            started_at: output_start_requested_at,
            once: true,
            servers: mcp_server_names.join(",")
          )
        end
        update = process_event(line, log_sink)
        if update&.delete(:assistant_text_seen)
          startup_timing.record("first_agent_message", started_at: output_start_requested_at, once: true)
        end
        if update&.delete(:mcp_seen)
          startup_timing.record("mcp_startup", started_at: output_start_requested_at, once: true, servers: mcp_server_names.join(","))
        end
        metadata.merge!(update.compact) if update
      end
    ).run
    if !runner_result.success? && metadata[:outcome].blank? && metadata[:startup_output].present?
      metadata[:is_error] = true
      metadata[:outcome] = "error"
      metadata[:final_text] = metadata[:startup_output]
    end
    log_codex_resume_failure(resume_session_id, runner_result, metadata, log_sink)

    # Same cleanup-timeout guard as ClaudeInvocation: if the provider
    # already emitted a successful result, don't fail on cleanup timeouts.
    provider_succeeded = metadata[:outcome].present? && !metadata[:is_error]
    cleanup_timeout    = provider_succeeded && (runner_result.timed_out || runner_result.silent_timed_out)

    transcript_path = rollout_path_for(codex_home, metadata[:session_id])
    AgentInvocation::Result.new(
      turns: metadata[:turns],
      exit_status: cleanup_timeout ? 0 : runner_result.exit_status,
      timed_out: !cleanup_timeout && (runner_result.timed_out || runner_result.silent_timed_out),
      is_error: metadata[:is_error],
      outcome: metadata[:outcome],
      final_text: metadata[:final_text],
      session_id: metadata[:session_id],
      transcript_path: transcript_path,
      transcript_jsonl: read_transcript(transcript_path),
      input_tokens: metadata[:input_tokens],
      output_tokens: metadata[:output_tokens],
      cache_creation_input_tokens: metadata[:cache_creation_input_tokens],
      cache_read_input_tokens: metadata[:cache_read_input_tokens]
    )
  end

  # The prompt is delivered on stdin (see `stdin_data:` in default_runner),
  # not as a positional arg. `codex exec -` reads the prompt from stdin; the
  # trailing `-` is codex's stdin sentinel. Passing a large prompt on argv
  # instead would overrun Linux's 128 KiB per-argument limit (MAX_ARG_STRLEN)
  # and fail with Errno::E2BIG "Argument list too long".
  def codex_command(workspace_path:, resume_session_id:)
    common = [ "--dangerously-bypass-approvals-and-sandbox", "--json" ]
    if resume_session_id.present?
      [ "codex", "exec", "resume", *common, resume_session_id, "-" ]
    else
      [ "codex", "exec", "--cd", workspace_path, *common, "-" ]
    end
  end

  def codex_env(api_key:, codex_home:)
    ProcessRunner.forwarded_env(
      AgentInvocation::ENV_FORWARD,
      extra: WorkspaceDependencyEnv.for(@workspace_path).merge(
        "CODEX_HOME" => codex_home,
        "CODEX_API_KEY" => api_key.presence
      )
    )
  end

  def write_config(codex_home, mcp_servers, model)
    FileUtils.mkdir_p(codex_home)
    path = File.join(codex_home, "config.toml")
    content = codex_config_toml(mcp_servers, model: model)
    return :unchanged if File.exist?(path) && File.read(path) == content

    File.write(path, content)
    :written
  end

  def codex_config_toml(mcp_servers, model:)
    lines = [
      'cli_auth_credentials_store = "file"',
      'approval_policy = "never"'
    ]
    lines << "model = #{toml_string(model)}" if model.present?

    normalized_mcp_servers(mcp_servers).each do |name, server|
      lines += [
        "",
        "[mcp_servers.#{name}]",
        "command = #{toml_string(server.fetch(:command))}",
        "args = #{toml_array(server.fetch(:args, []))}",
        "required = #{server.fetch(:required, true) ? 'true' : 'false'}",
        "startup_timeout_sec = #{server.fetch(:startup_timeout_sec, MCP_STARTUP_TIMEOUT_SECONDS)}",
        "tool_timeout_sec = #{server.fetch(:tool_timeout_sec, MCP_TOOL_TIMEOUT_SECONDS)}"
      ]

      env = server.fetch(:env, {}).compact
      if env.any?
        lines << ""
        lines << "[mcp_servers.#{name}.env]"
        env.each do |key, value|
          lines << "#{key} = #{toml_string(value)}"
        end
      end
    end

    lines.join("\n") + "\n"
  end

  def normalized_mcp_servers(value)
    return {} unless value
    if value.key?(:command) || value.key?("command")
      return { "syrus-mcp-sidecar" => value.transform_keys(&:to_sym) }
    end

    value.to_h.transform_keys(&:to_s).transform_values do |server|
      server.transform_keys(&:to_sym)
    end
  end

  def toml_string(value)
    JSON.generate(value.to_s)
  end

  def toml_array(values)
    "[#{values.map { |value| toml_string(value) }.join(', ')}]"
  end

  def process_event(line, log_sink)
    event = JSON.parse(line.strip)
    case event["type"]
    when "thread.started"
      { session_id: event["thread_id"] }
    when "turn.completed"
      usage = event["usage"] || {}
      log_sink.call(
        "[codex result] input_tokens=#{usage['input_tokens']}, output_tokens=#{usage['output_tokens']}, reasoning_output_tokens=#{usage['reasoning_output_tokens']}",
        kind: "system"
      )
      { turns: 1, is_error: false, outcome: "success" }
        .merge(
          input_tokens: usage["input_tokens"],
          output_tokens: usage["output_tokens"],
          cache_creation_input_tokens: nil,
          cache_read_input_tokens: usage["cached_input_tokens"]
        )
    when "turn.failed"
      message = event["error"] || event["message"] || "turn failed"
      detail = message.to_s
      scoped_detail = codex_error_detail(detail)
      detail = scoped_detail if ProviderUsageLimit.detect?(scoped_detail)
      log_sink.call("[codex error] #{detail}", kind: "system")
      if ProviderUsageLimit.detect?(detail)
        return {
          is_error: true,
          outcome: ProviderUsageLimit::OUTCOME,
          final_text: detail
        }
      end

      { is_error: true, outcome: "turn_failed", final_text: detail }
    when "error"
      message = event["message"] || event["error"] || "error"
      detail = message.to_s
      scoped_detail = codex_error_detail(detail)
      detail = scoped_detail if ProviderUsageLimit.detect?(scoped_detail)
      log_sink.call("[codex error] #{detail}", kind: "system")
      if ProviderUsageLimit.detect?(detail)
        return {
          is_error: true,
          outcome: ProviderUsageLimit::OUTCOME,
          final_text: detail
        }
      end

      { is_error: true, outcome: "error", final_text: detail }
    when "item.started", "item.completed"
      process_item_event(event, log_sink)
    else
      nil
    end
  rescue JSON::ParserError
    detail = line.chomp
    log_sink.call(detail)
    detail.present? ? { startup_output: detail } : nil
  end

  def codex_error_detail(message)
    [ "model #{@model}", message.to_s ].compact.join(": ")
  end

  def process_item_event(event, log_sink)
    item = event["item"] || {}
    status = item["status"] || event["type"].sub("item.", "")
    item_id = event["id"].presence || item["id"].presence
    case item["type"]
    when "agent_message"
      text = item["text"].to_s
      log_sink.call(text, kind: "assistant_text") if text.present?
      { final_text: text, assistant_text_seen: text.present? }
    when "mcp_tool_call"
      tool_name = [ item["server"], item["tool"] ].compact.join(".")
      return nil if tool_name.blank?

      if item["error"]
        error_content = codex_item_error_content(item)
        error_message = codex_item_error_message(error_content)
        log_sink.call(
          "[codex mcp] #{tool_name} #{status}: #{error_message}",
          kind: "tool_result",
          tool_name: tool_name,
          tool_result_content: error_content,
          tool_result_error: true,
          tool_use_id: item_id
        )
      elsif item["result"]
        log_sink.call(
          "[codex mcp] #{tool_name} #{status}",
          kind: "tool_result",
          tool_name: tool_name,
          tool_result_content: item["result"],
          tool_result_error: false,
          tool_use_id: item_id
        )
      else
        log_sink.call(
          "[codex mcp] #{tool_name} #{status}",
          kind: "tool_call",
          tool_name: tool_name,
          tool_input: item["arguments"],
          tool_use_id: item_id
        )
      end
      { mcp_seen: true }
    when "command_execution"
      command = item["command"].to_s
      return nil if command.blank?

      if item["output"] || item["error"]
        result_content =
          if item["error"].present?
            codex_item_error_content(item, prefer_output: true)
          else
            item["output"]
          end
        log_sink.call(
          "[codex command] #{command} #{status}",
          kind: "tool_result",
          tool_name: "bash",
          tool_result_content: result_content,
          tool_result_error: item["error"].present?,
          tool_use_id: item_id
        )
      else
        log_sink.call(
          "[codex command] #{command} #{status}",
          kind: "tool_call",
          tool_name: "bash",
          tool_input: { "command" => command },
          tool_use_id: item_id
        )
      end
      nil
    when "file_change"
      log_sink.call("[codex file] #{item['path']} #{status}", kind: "system")
      nil
    else
      nil
    end
  end

  def codex_item_error_content(item, prefer_output: false)
    error = item["error"]
    if prefer_output
      return item["output"] if item["output"].present?
      return item["result"] if item["result"].present?
    end

    return error["message"] if error.is_a?(Hash) && error["message"].present?
    return error if error.is_a?(String) && error.present?
    return item["output"] if item["output"].present?
    return item["result"] if item["result"].present?
    return error if error.is_a?(Hash) && error.present?

    "Codex reported tool failure without details."
  end

  def codex_item_error_message(content)
    if content.is_a?(Array)
      text = content.filter_map { |part| part["text"] if part.is_a?(Hash) }.join("\n")
      return text if text.present?
    end

    return content if content.is_a?(String)

    JSON.generate(content)
  rescue JSON::GeneratorError
    content.to_s
  end

  def codex_mcp_tool_name(item)
    server = item["server"].presence
    tool = item["tool"].presence || item["name"].presence
    return nil if server.blank? && tool.blank?

    [ "mcp", server, tool ].compact.join("__")
  end

  def rollout_path_for(codex_home, session_id)
    return nil if session_id.blank?
    Dir.glob(File.join(codex_home, "sessions", "**", "*#{session_id}.jsonl")).max_by { |path| File.mtime(path) }
  end

  def read_transcript(path)
    return nil if path.blank? || !File.exist?(path)
    File.read(path)
  end

  def restore_resume_transcript(codex_home, session_id, jsonl, log_sink)
    return if session_id.blank?
    return if rollout_path_for(codex_home, session_id).present?

    if jsonl.blank?
      log_sink.call(
        "[codex resume] no stored rollout JSONL for session #{session_id}; provider resume may be rejected or incomplete",
        kind: "system"
      )
      return
    end

    dir = File.join(codex_home, "sessions", Time.now.utc.strftime("%Y/%m/%d"))
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "rollout-restored-#{session_id}.jsonl")
    File.write(path, jsonl)
  end

  def log_codex_resume_failure(session_id, runner_result, metadata, log_sink)
    return if session_id.blank?
    return if runner_result.success? && metadata[:outcome] == "success"

    reason = metadata[:final_text].presence || metadata[:outcome].presence || "codex exited with status #{runner_result.exit_status || 'unknown'}"
    log_sink.call(
      "[codex resume] resume for session #{session_id} did not complete successfully: #{reason}",
      kind: "system"
    )
  end
end
