require "fileutils"
require "json"
require "securerandom"

class MuseInvocation
  DEFAULT_TIMEOUT_SECONDS = AgentInvocation::DEFAULT_TIMEOUT_SECONDS
  DEFAULT_TRANSCRIPT_POLICY = :redacted_export
  TRANSCRIPT_POLICIES = %i[redacted_export raw_export exec_jsonl].freeze
  STARTUP_ERROR_MAX_BYTES = 4.kilobytes

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

    Dir.mktmpdir("syrus-muse-invocation-") do |tmpdir|
      prompt_path = File.join(tmpdir, "prompt.txt")
      File.write(prompt_path, prompt)

      runner_result = ProcessRunner.new(
        env: muse_env(workspace_path),
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
        stop_requested: stop_requested,
        on_spawned_process: process_started,
        on_output_line: ->(line) do
          exec_jsonl << line
          exec_jsonl << "\n" unless line.end_with?("\n")
          update = process_event(line, log_sink)
          metadata.merge!(update.compact) if update
        end
      ).run

      apply_missing_terminal_failure!(metadata, runner_result) if metadata[:outcome].blank?
      cleanup_timeout = cleanup_timeout?(metadata, runner_result)
      transcript = capture_transcript(
        workspace_path: workspace_path,
        session_id: session_id,
        policy: transcript_policy,
        transcript_dir: transcript_dir || tmpdir,
        exec_jsonl: exec_jsonl,
        log_sink: log_sink,
        stop_requested: stop_requested
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

  def muse_env(workspace_path)
    ProcessRunner.forwarded_env(
      AgentInvocation::ENV_FORWARD,
      extra: WorkspaceDependencyEnv.for(workspace_path)
    )
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
      *optional_flag("--max-model-steps", max_model_steps)
    ]
  end

  def optional_flag(name, value)
    return [] if value.blank?

    [ name, value.to_s ]
  end

  def process_event(line, log_sink)
    event = JSON.parse(line.strip)
    return malformed_startup_output(line, log_sink) unless event.is_a?(Hash)

    payload_type = event["payload_type"].presence || event["type"].presence
    payload = event["payload"].is_a?(Hash) ? event["payload"] : {}

    case payload_type
    when "session.created", "run.session.created", "run.started"
      session = payload["session_id"].presence || payload["session"].presence
      session ? { session_id: session } : nil
    when "assistant.message", "assistant.text", "message.assistant"
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
      classified_failure(detail)
    else
      nil
    end
  rescue JSON::ParserError
    malformed_startup_output(line, log_sink)
  end

  def malformed_startup_output(line, log_sink)
    detail = sanitize(line.chomp)
    log_sink.call(detail) if detail.present?
    detail.present? ? { startup_output: detail } : nil
  end

  def payload_text(payload)
    payload["final_text"].presence ||
      payload["result"].presence ||
      payload["text"].presence ||
      payload["message"].presence ||
      payload["output"].presence
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

  def classified_failure(detail)
    if ProviderUsageLimit.detect?(detail)
      { is_error: true, outcome: ProviderUsageLimit::OUTCOME, final_text: detail }
    elsif ProviderAuthFailure.detect?(detail) || detail.match?(/\b(?:invalid|expired|missing)\s+(?:api\s+)?key\b/i)
      { is_error: true, outcome: ProviderAuthFailure::OUTCOME, final_text: detail }
    else
      { is_error: true, outcome: "run_failed", final_text: detail }
    end
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
      env: muse_env(workspace_path),
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
