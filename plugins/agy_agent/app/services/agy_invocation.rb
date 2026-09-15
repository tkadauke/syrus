require "fileutils"
require "json"

class AgyInvocation
  DEFAULT_TIMEOUT_SECONDS = AgentInvocation::DEFAULT_TIMEOUT_SECONDS
  STARTUP_ERROR_MAX_BYTES = 4.kilobytes

  def self.configured_model
    ENV["SYRUS_AGY_MODEL"].to_s.strip.presence
  end

  def self.configured_effort
    ENV["SYRUS_AGY_EFFORT"].to_s.strip.presence
  end

  def initialize(workspace_path, prompt:,
                 api_key: nil,
                 log_sink: ->(*, **) { },
                 runner: nil,
                 timeout: DEFAULT_TIMEOUT_SECONDS,
                 agy_home: nil,
                 resume_session_id: nil,
                 resume_transcript_jsonl: nil,
                 mcp_server: nil,
                 model: nil,
                 effort_level: nil,
                 required_mcp_tools: nil,
                 stop_requested: -> { false },
                 process_started: ->(_process) { },
                 on_session_id: ->(_session_id) { })
    @workspace_path = workspace_path.to_s
    @prompt = prompt
    @api_key = api_key
    @log_sink = log_sink
    @runner = runner || method(:default_runner)
    @timeout = timeout
    @agy_home = agy_home&.to_s
    @resume_session_id = resume_session_id
    @resume_transcript_jsonl = resume_transcript_jsonl
    @mcp_server = mcp_server
    @model = model.to_s.strip.presence || self.class.configured_model
    @effort_level = effort_level.to_s.strip.presence || self.class.configured_effort
    @required_mcp_tools = Array(required_mcp_tools).compact_blank.map(&:to_s)
    @stop_requested = stop_requested
    @process_started = process_started
    @on_session_id = on_session_id
  end

  def run
    @runner.call(
      workspace_path: @workspace_path,
      prompt: @prompt,
      api_key: @api_key,
      log_sink: @log_sink,
      timeout: @timeout,
      agy_home: @agy_home,
      resume_session_id: @resume_session_id,
      resume_transcript_jsonl: @resume_transcript_jsonl,
      mcp_server: @mcp_server,
      model: @model,
      effort_level: @effort_level,
      required_mcp_tools: @required_mcp_tools,
      stop_requested: @stop_requested,
      process_started: @process_started,
      on_session_id: @on_session_id
    )
  end

  private

  def default_runner(workspace_path:, prompt:, api_key: nil, log_sink:, timeout:, agy_home: nil,
                     resume_session_id: nil, resume_transcript_jsonl: nil,
                     mcp_server: nil, model: nil, effort_level: nil,
                     required_mcp_tools: nil,
                     stop_requested: -> { false }, process_started: ->(_process) { },
                     on_session_id: ->(_session_id) { })
    agy_home = agy_home.presence || File.join(Dir.home, ".agy")
    FileUtils.mkdir_p(agy_home)
    write_mcp_config(agy_home, mcp_server, log_sink) if mcp_server
    restored_resume = restore_resume_transcript(
      agy_home: agy_home,
      workspace_path: workspace_path,
      session_id: resume_session_id,
      jsonl: resume_transcript_jsonl,
      log_sink: log_sink
    )
    effective_resume_session_id = restored_resume == :resume_unavailable ? nil : resume_session_id

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
    mcp_server_failed = false
    required_mcp_tools = Array(required_mcp_tools).compact_blank.map(&:to_s)
    current_run = Thread.current[:syrus_current_run]
    current_chat_session = Thread.current[:syrus_current_chat_session]
    current_agent =
      Thread.current[:syrus_current_agent] ||
      (Agent.find_or_create_for!(current_run || current_chat_session) if current_run || current_chat_session)

    runner_result = ProcessRunner.new(
      env: agy_env(workspace_path: workspace_path, agy_home: agy_home, api_key: api_key, model: model, effort_level: effort_level),
      command: agy_command(resume_session_id: effective_resume_session_id),
      stdin_data: stdin_event(prompt),
      chdir: workspace_path,
      timeout: timeout,
      silent_timeout: AgentInvocation::SILENT_TIMEOUT_SECONDS,
      kind: "agent",
      run: current_run,
      workflow: current_run&.workflow,
      chat_session: current_chat_session,
      agent: current_agent,
      stop_requested: stop_requested,
      on_spawned_process: process_started,
      on_output_line: ->(line) do
        update = process_event(line, log_sink, required_mcp_tools: required_mcp_tools)
        if update
          on_session_id.call(update[:session_id]) if update[:session_id].present?
          mcp_server_failed = true if update.delete(:mcp_server_failed)
          metadata.merge!(update.compact)
        end
      end
    ).run
    log_resume_failure(effective_resume_session_id, runner_result, metadata, log_sink)

    if mcp_server_failed
      metadata[:is_error] = true
      metadata[:outcome] = "mcp_sidecar_failed"
      metadata[:final_text] = nil
    elsif metadata[:outcome].blank?
      metadata[:is_error] = true
      metadata[:outcome] = runner_result.success? ? "missing_result" : process_failure_outcome(runner_result)
      metadata[:final_text] = metadata[:startup_output].presence || process_failure_message(runner_result)
    elsif !runner_result.success? && metadata[:is_error] == false
      metadata[:is_error] = true
      metadata[:outcome] = process_failure_outcome(runner_result)
      metadata[:final_text] = process_failure_message(runner_result)
    end

    provider_succeeded = metadata[:outcome].present? && !metadata[:is_error]
    cleanup_timeout = provider_succeeded && (runner_result.timed_out || runner_result.silent_timed_out)
    transcript_path = AgyAgent::SessionPaths.transcript_path_for(
      home: agy_home,
      cwd: workspace_path,
      session_id: metadata[:session_id]
    )

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
      cache_read_input_tokens: metadata[:cache_read_input_tokens],
      process_outcome: process_outcome(runner_result),
      spawned_process_id: runner_result.spawned_process_id,
      silent_timed_out: !cleanup_timeout && runner_result.silent_timed_out,
      stopped: runner_result.stopped,
      operator_killed: runner_result.operator_killed,
      aliveness_failed: runner_result.aliveness_failed
    )
  end

  def agy_command(resume_session_id:)
    command = [
      "agy",
      "--input-format", "stream-json",
      "--output-format", "stream-json",
      "--print=",
      "--dangerously-skip-permissions",
      "--disable-slash-commands",
      "--print-timeout", "90m"
    ]
    command += [ "--conversation", resume_session_id ] if resume_session_id.present?
    command
  end

  def stdin_event(prompt)
    { event: "user", message: { content: prompt.to_s } }.to_json + "\n"
  end

  def agy_env(workspace_path:, agy_home:, api_key:, model:, effort_level:)
    ProcessRunner.forwarded_env(
      AgentInvocation::ENV_FORWARD,
      extra: WorkspaceDependencyEnv.for(workspace_path).merge(
        "HOME" => agy_home,
        "AGY_HOME" => agy_home,
        "ANTIGRAVITY_HOME" => agy_home,
        "GEMINI_API_KEY" => api_key.presence,
        "GOOGLE_API_KEY" => api_key.presence,
        "SYRUS_AGY_MODEL" => model.presence,
        "SYRUS_AGY_EFFORT" => effort_level.presence,
        "AGY_MODEL" => model.presence,
        "AGY_EFFORT" => effort_level.presence
      )
    )
  end

  def write_mcp_config(agy_home, mcp_server, log_sink)
    config = {
      mcpServers: {
        "syrus-mcp-sidecar" => {
          command: mcp_server.fetch(:command),
          args: Array(mcp_server[:args]),
          env: mcp_server.fetch(:env, {}).compact
        }
      }
    }
    path = File.join(agy_home, ".gemini", "config", "mcp_config.json")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.pretty_generate(config) + "\n")
    log_sink.call(
      "[mcp_config] server=syrus-mcp-sidecar command=#{mcp_server[:command]} args=#{Array(mcp_server[:args]).join(' ')} path=#{path} env_keys=#{config[:mcpServers]['syrus-mcp-sidecar'][:env].keys.sort.join(',')}",
      kind: "system"
    )
    path
  end

  def restore_resume_transcript(agy_home:, workspace_path:, session_id:, jsonl:, log_sink:)
    return if session_id.blank?

    unless AgyAgent::SessionPaths.valid_session_id?(session_id)
      log_sink.call(
        "[agy resume] invalid conversation id #{session_id}; starting a fresh Antigravity session",
        kind: "system"
      )
      return :resume_unavailable
    end

    return if AgyAgent::SessionPaths.transcript_path_for(home: agy_home, cwd: workspace_path, session_id: session_id).present?

    if jsonl.blank?
      log_sink.call(
        "[agy resume] no stored JSONL for conversation #{session_id}; provider resume may be rejected or incomplete",
        kind: "system"
      )
      return
    end

    AgyAgent::SessionPaths.restore!(
      home: agy_home,
      cwd: workspace_path,
      session_id: session_id,
      transcript_jsonl: jsonl
    )
  end

  def process_event(line, log_sink, required_mcp_tools: [])
    event = JSON.parse(line.strip)
    return malformed_startup_output(line, log_sink) unless event.is_a?(Hash)

    case event_name(event)
    when "init"
      log_sink.call("[agy init] conversation_id=#{event['conversation_id']} permission_mode=#{event['permission_mode']}", kind: "system")
      { session_id: event["conversation_id"], turns: event["num_turns"] }
        .merge(required_mcp_tools_update(event, required_mcp_tools, log_sink) || {})
    when "step_update"
      process_step_update(event, log_sink)
    when "result"
      process_result(event, log_sink)
    when "error"
      process_error(event, log_sink)
    else
      nil
    end
  rescue JSON::ParserError
    malformed_startup_output(line, log_sink)
  end

  def event_name(event)
    event["event"].presence || event["type"].presence
  end

  def process_step_update(event, log_sink)
    text = event.dig("message", "content").presence || event["message"].presence || event["content"].presence || event["text"].presence
    log_sink.call(text, kind: "assistant_text") if text.present?
    text.present? ? { final_text: text } : nil
  end

  def required_mcp_tools_update(event, required_mcp_tools, log_sink)
    return if required_mcp_tools.empty?

    available_tools = Array(event["tools"]).map(&:to_s)
    if available_tools.any?
      missing_tools = required_mcp_tools.reject { |tool| mcp_tool_matches?(available_tools, tool) }
      log_sink.call(
        "[mcp_tools_init] count=#{available_tools.size} required=#{required_mcp_tools.join(',')} tools=#{available_tools.join(',')}",
        kind: "system"
      )
      return if missing_tools.empty?

      log_sink.call(
        "[mcp_required] required tools missing from Agy init tool list: #{missing_tools.join(', ')}",
        kind: "system"
      )
      return { mcp_server_failed: true, is_error: true, outcome: "mcp_sidecar_failed", final_text: nil }
    end

    servers = Array(event["mcp_servers"])
    return unless servers.any?

    sidecar = servers.find { |server| server["name"] == "syrus-mcp-sidecar" }
    status = sidecar&.fetch("status", nil).presence || "missing"
    return if status.in?(%w[connected pending])

    log_sink.call(
      "[mcp_required] syrus-mcp-sidecar=#{status}; required tools unavailable: #{required_mcp_tools.join(', ')}",
      kind: "system"
    )
    { mcp_server_failed: true, is_error: true, outcome: "mcp_sidecar_failed", final_text: nil }
  end

  def mcp_tool_matches?(available_tools, required_tool)
    agy_name = AgentProviders::Agy.mcp_tool_name(required_tool, server_name: "syrus-mcp-sidecar")
    available_tools.any? do |name|
      name == required_tool ||
        name == agy_name ||
        name.end_with?("/#{required_tool})") ||
        name.end_with?("_#{required_tool}")
    end
  end

  def process_result(event, log_sink)
    usage = event["usage"] || {}
    text = event["result"].presence || event["text"].presence || event.dig("message", "content")
    turns = event["num_turns"].presence || event["turns"].presence
    is_error = event["is_error"] == true || event["subtype"].to_s == "error"
    outcome = is_error ? error_outcome(text.presence || event["error"]) : (event["subtype"].presence || "success")

    log_sink.call(
      "[agy result] outcome=#{outcome} turns=#{turns} input_tokens=#{usage_value(usage, 'input')} output_tokens=#{usage_value(usage, 'output')} thinking_tokens=#{usage_value(usage, 'thinking')} cache_tokens=#{usage_value(usage, 'cache')} total_tokens=#{usage_value(usage, 'total')}",
      kind: "system"
    )

    {
      turns: turns,
      is_error: is_error,
      outcome: outcome,
      final_text: text,
      input_tokens: usage_value(usage, "input"),
      output_tokens: usage_value(usage, "output"),
      cache_creation_input_tokens: usage_value(usage, "thinking"),
      cache_read_input_tokens: usage_value(usage, "cache")
    }
  end

  def process_error(event, log_sink)
    detail = (event["message"].presence || event["error"].presence || "Agy reported an error.").to_s
    log_sink.call("[agy error] #{detail}", kind: "system")
    { is_error: true, outcome: error_outcome(detail), final_text: detail }
  end

  def error_outcome(detail)
    return ProviderUsageLimit::OUTCOME if ProviderUsageLimit.detect?(detail)
    return ProviderAuthFailure::OUTCOME if ProviderAuthFailure.detect?(detail)

    "error"
  end

  def usage_value(usage, name)
    usage["#{name}_tokens"] || usage["#{name}_token_count"] || usage[name]
  end

  def malformed_startup_output(line, log_sink)
    detail = line.to_s.chomp.safe_byteslice(0, STARTUP_ERROR_MAX_BYTES)
    log_sink.call(detail)
    detail.present? ? { startup_output: detail } : nil
  end

  def read_transcript(path)
    return nil if path.blank? || !File.exist?(path)

    File.read(path)
  end

  def log_resume_failure(session_id, runner_result, metadata, log_sink)
    return if session_id.blank?
    return if runner_result.success? && metadata[:outcome] == "success"

    reason = metadata[:final_text].presence || metadata[:outcome].presence || "agy exited with status #{runner_result.exit_status || 'unknown'}"
    log_sink.call(
      "[agy resume] resume for conversation #{session_id} did not complete successfully: #{reason}",
      kind: "system"
    )
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

    "Agy process ended without a result event: #{detail}."
  end
end
