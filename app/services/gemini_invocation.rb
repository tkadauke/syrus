require "fileutils"
require "json"

class GeminiInvocation
  DEFAULT_TIMEOUT_SECONDS = AgentInvocation::DEFAULT_TIMEOUT_SECONDS
  DEFAULT_MODEL = "gemini-3-pro"

  def initialize(workspace_path, prompt:, api_key:,
                 log_sink: ->(*, **) { },
                 runner: nil,
                 timeout: DEFAULT_TIMEOUT_SECONDS,
                 model: nil,
                 mcp_config: nil,
                 resume_session_id: nil,
                 env: nil,
                 stop_requested: -> { false },
                 process_started: ->(_process) { })
    @workspace_path = workspace_path.to_s
    @prompt = prompt
    @api_key = api_key
    @log_sink = log_sink
    @runner = runner || method(:default_runner)
    @timeout = timeout
    @model = model.presence || ENV.fetch("SYRUS_GEMINI_MODEL", DEFAULT_MODEL).presence
    @mcp_config = mcp_config
    @resume_session_id = resume_session_id
    @env = env || {}
    @stop_requested = stop_requested
    @process_started = process_started
  end

  def run
    @runner.call(
      workspace_path: @workspace_path,
      prompt: @prompt,
      api_key: @api_key,
      log_sink: @log_sink,
      timeout: @timeout,
      model: @model,
      mcp_config: @mcp_config,
      resume_session_id: @resume_session_id,
      env: @env,
      stop_requested: @stop_requested,
      process_started: @process_started
    )
  end

  private

  def default_runner(workspace_path:, prompt:, api_key:, log_sink:, timeout:,
                     model:, mcp_config: nil, resume_session_id: nil, env: nil,
                     stop_requested: -> { false }, process_started: ->(_process) { })
    transcript_lines = []
    metadata = {
      turns: nil,
      is_error: false,
      outcome: nil,
      final_text: nil,
      session_id: nil,
      cost_usd: nil,
      input_tokens: nil,
      output_tokens: nil,
      cache_creation_input_tokens: nil,
      cache_read_input_tokens: nil
    }
    current_run = Thread.current[:syrus_current_run]
    runner_result = ProcessRunner.new(
      env: gemini_env(api_key: api_key, workspace_path: workspace_path).merge(env || {}),
      command: gemini_command(prompt: prompt, model: model, mcp_config: mcp_config, resume_session_id: resume_session_id),
      chdir: workspace_path,
      timeout: timeout,
      silent_timeout: AgentInvocation::SILENT_TIMEOUT_SECONDS,
      kind: "agent",
      run: current_run,
      workflow: current_run&.workflow,
      stop_requested: stop_requested,
      on_spawned_process: process_started,
      on_output_line: ->(line) do
        transcript_lines << line.chomp
        update = process_event(line, log_sink)
        metadata.merge!(update.compact) if update
      end
    ).run

    transcript_jsonl = transcript_lines.join("\n")
    transcript_jsonl += "\n" if transcript_jsonl.present?
    transcript_path = write_transcript(workspace_path, metadata[:session_id], transcript_jsonl)

    AgentInvocation::Result.new(
      turns: metadata[:turns],
      exit_status: runner_result.exit_status,
      timed_out: runner_result.timed_out || runner_result.silent_timed_out,
      is_error: metadata[:is_error],
      outcome: metadata[:outcome],
      final_text: metadata[:final_text],
      session_id: metadata[:session_id],
      transcript_jsonl: transcript_jsonl.presence,
      transcript_path: transcript_path,
      cost_usd: metadata[:cost_usd],
      input_tokens: metadata[:input_tokens],
      output_tokens: metadata[:output_tokens],
      cache_creation_input_tokens: metadata[:cache_creation_input_tokens],
      cache_read_input_tokens: metadata[:cache_read_input_tokens]
    )
  end

  def gemini_command(prompt:, model:, mcp_config:, resume_session_id:)
    cmd = [ "gemini" ]
    cmd += [ "-r", resume_session_id ] if resume_session_id.present?
    cmd += [ "-p", prompt, "--yolo", "--output-format", "stream-json" ]
    cmd += [ "--model", model ] if model.present?
    cmd += [ "--mcp-config", mcp_config ] if mcp_config.present?
    cmd
  end

  def gemini_env(api_key:, workspace_path:)
    ProcessRunner.forwarded_env(
      AgentInvocation::ENV_FORWARD,
      extra: WorkspaceDependencyEnv.for(workspace_path).merge(
        "GEMINI_API_KEY" => api_key.presence,
        "GEMINI_CLI_TRUST_WORKSPACE" => "true"
      )
    )
  end

  def process_event(line, log_sink)
    event = JSON.parse(line.strip)
    case event["type"]
    when "init"
      process_init_event(event, log_sink)
    when "message"
      process_message_event(event, log_sink)
    when "tool_use", "tool_call"
      process_tool_use_event(event, log_sink)
    when "tool_result"
      process_tool_result_event(event, log_sink)
    when "error"
      process_error_event(event, log_sink)
    when "result"
      process_result_event(event, log_sink)
    else
      nil
    end
  rescue JSON::ParserError
    log_sink.call(line.chomp)
    nil
  end

  def process_init_event(event, log_sink)
    if event["mcp_servers"]
      servers = event["mcp_servers"].map { |server| { "name" => server["name"], "status" => server["status"] } }
      log_sink.call(
        "[mcp_servers] #{servers.map { |s| "#{s['name']}=#{s['status']}" }.join(', ')}",
        kind: "system",
        mcp_servers: servers
      )
    end

    { session_id: event["session_id"] || event["sessionId"], final_text: nil }.compact
  end

  def process_message_event(event, log_sink)
    return unless event["role"].to_s == "assistant"

    text = message_text(event)
    log_sink.call(text, kind: "assistant_text") if text.present?
    { final_text: text.presence }.compact
  end

  def process_tool_use_event(event, log_sink)
    tool_name = event["tool_name"] || event["name"] || event["toolName"]
    tool_input = event["args"] || event["input"] || event["arguments"] || {}
    log_sink.call(
      AgentEventAbbreviator.tool_use(
        tool_name,
        tool_input,
        path_roots: [ @workspace_path ]
      ),
      kind: "tool_call",
      tool_name: tool_name,
      tool_input: tool_input
    )
    nil
  end

  def process_tool_result_event(event, log_sink)
    error = event["status"].to_s == "error" || event["is_error"] == true || event["error"].present?
    content = event["content"] || event["result"] || event["output"] || event["error"] || ""
    log_sink.call(
      AgentEventAbbreviator.tool_result(content, error: error),
      kind: "tool_result",
      tool_result_content: content,
      tool_result_error: error,
      tool_use_id: event["tool_use_id"] || event["toolUseId"]
    )
    nil
  end

  def process_error_event(event, log_sink)
    message = event.dig("error", "message") || event["message"] || event["error"] || "Gemini CLI error"
    severity = event["severity"].presence || "error"
    log_sink.call("[gemini #{severity}] #{message}", kind: "system")
    {
      is_error: severity.to_s == "error",
      outcome: severity.to_s == "error" ? "error" : nil,
      final_text: severity.to_s == "error" ? message.to_s : nil
    }
  end

  def process_result_event(event, log_sink)
    usage = event["usage"] || event["stats"] || event["token_usage"] || {}
    status = event["status"] || event["subtype"] || (event["error"].present? ? "error" : "success")
    error_message = event.dig("error", "message") || event["error"]
    final_text = event["response"] || event["result"] || event["text"] || error_message

    log_sink.call(
      "[gemini result] status=#{status}, input_tokens=#{token_value(usage, 'input_tokens')}, output_tokens=#{token_value(usage, 'output_tokens')}, total_tokens=#{token_value(usage, 'total_tokens')}, cost_usd=#{cost_value(event, usage)}",
      kind: "system"
    )

    {
      turns: event["turns"] || event["num_turns"] || 1,
      is_error: status.to_s == "error" || event["is_error"] == true,
      outcome: status,
      final_text: final_text,
      cost_usd: cost_value(event, usage),
      input_tokens: token_value(usage, "input_tokens"),
      output_tokens: token_value(usage, "output_tokens"),
      cache_creation_input_tokens: token_value(usage, "cache_creation_input_tokens"),
      cache_read_input_tokens: token_value(usage, "cache_read_input_tokens")
    }
  end

  def message_text(event)
    content = event["content"] || event["text"]
    return content if content.is_a?(String)

    Array(content).filter_map do |part|
      if part.is_a?(Hash)
        part["text"] || part["content"]
      elsif part.is_a?(String)
        part
      end
    end.join
  end

  def token_value(usage, snake_name)
    camel_name = snake_name.camelize(:lower)
    google_name = case snake_name
                  when "input_tokens" then "promptTokenCount"
                  when "output_tokens" then "candidatesTokenCount"
                  when "cache_creation_input_tokens" then "cacheCreationInputTokenCount"
                  when "cache_read_input_tokens" then "cachedContentTokenCount"
                  end
    usage[snake_name] || usage[camel_name] || usage[google_name] || usage[snake_name.gsub("_tokens", "TokenCount")]
  end

  def cost_value(event, usage)
    event["cost_usd"] || event["total_cost_usd"] || usage["cost_usd"] || usage["total_cost_usd"]
  end

  def write_transcript(workspace_path, session_id, transcript_jsonl)
    return nil if transcript_jsonl.blank?

    dir = File.join(workspace_path, ".syrus", "agent-transcripts")
    FileUtils.mkdir_p(dir)
    safe_session_id = session_id.to_s.presence&.gsub(/[^A-Za-z0-9_.-]/, "_") || "unknown"
    path = File.join(dir, "gemini-#{safe_session_id}.jsonl")
    File.write(path, transcript_jsonl)
    path
  end
end
