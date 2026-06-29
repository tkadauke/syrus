require "fileutils"
require "json"

class OpenCodeInvocation
  DEFAULT_TIMEOUT_SECONDS = AgentInvocation::DEFAULT_TIMEOUT_SECONDS
  CONFIG_SCHEMA = "https://opencode.ai/config.json".freeze
  API_KEY_ENV = "SYRUS_OPENCODE_API_KEY".freeze

  BackendConfig = Data.define(:backend, :model, :api_key, :endpoint_url)

  def initialize(workspace_path, prompt:,
                 backend_config:,
                 log_sink: ->(*, **) { },
                 runner: nil,
                 timeout: DEFAULT_TIMEOUT_SECONDS,
                 opencode_home: nil,
                 mcp_server: nil,
                 resume_session_id: nil,
                 resume_transcript_jsonl: nil)
    @workspace_path = workspace_path.to_s
    @prompt = prompt
    @backend_config = backend_config
    @log_sink = log_sink
    @runner = runner || method(:default_runner)
    @timeout = timeout
    @opencode_home = opencode_home&.to_s
    @mcp_server = mcp_server
    @resume_session_id = resume_session_id
    @resume_transcript_jsonl = resume_transcript_jsonl
  end

  def run
    @runner.call(
      workspace_path: @workspace_path,
      prompt: @prompt,
      backend_config: @backend_config,
      log_sink: @log_sink,
      timeout: @timeout,
      opencode_home: @opencode_home,
      mcp_server: @mcp_server,
      resume_session_id: @resume_session_id,
      resume_transcript_jsonl: @resume_transcript_jsonl
    )
  end

  private

  def default_runner(workspace_path:, prompt:, backend_config:, log_sink:, timeout:,
                     opencode_home:, mcp_server: nil, resume_session_id: nil,
                     resume_transcript_jsonl: nil)
    opencode_home = opencode_home.presence || File.join(Dir.home, ".syrus", "opencode")
    FileUtils.mkdir_p(opencode_home)
    restore_resume_transcript(opencode_home, resume_session_id, resume_transcript_jsonl)

    config_path = File.join(opencode_home, "opencode.json")
    File.write(config_path, JSON.pretty_generate(opencode_config_json(backend_config, mcp_server)) + "\n")

    transcript_path = transcript_path_for(opencode_home, resume_session_id || "new")
    transcript = +""
    metadata = {
      turns: nil,
      is_error: false,
      outcome: nil,
      final_text: nil,
      session_id: resume_session_id,
      cost_usd: nil,
      input_tokens: nil,
      output_tokens: nil,
      cache_creation_input_tokens: nil,
      cache_read_input_tokens: nil
    }

    current_run = Thread.current[:syrus_current_run]
    runner_result = ProcessRunner.new(
      env: opencode_env(backend_config: backend_config, opencode_home: opencode_home, config_path: config_path),
      command: opencode_command(workspace_path: workspace_path,
                                prompt: prompt,
                                model: config_model(backend_config),
                                resume_session_id: resume_session_id),
      chdir: workspace_path,
      timeout: timeout,
      silent_timeout: AgentInvocation::SILENT_TIMEOUT_SECONDS,
      kind: "agent",
      run: current_run,
      workflow: current_run&.workflow,
      on_output_line: ->(line) do
        transcript << line
        update = process_event(line, log_sink)
        metadata.merge!(update.compact) if update
      end
    ).run

    final_transcript_path = write_transcript(transcript_path, metadata[:session_id], transcript)
    AgentInvocation::Result.new(
      turns: metadata[:turns],
      exit_status: runner_result.exit_status,
      timed_out: runner_result.timed_out || runner_result.silent_timed_out,
      is_error: metadata[:is_error],
      outcome: metadata[:outcome],
      final_text: metadata[:final_text],
      session_id: metadata[:session_id],
      transcript_path: final_transcript_path,
      transcript_jsonl: transcript.presence,
      cost_usd: metadata[:cost_usd],
      input_tokens: metadata[:input_tokens],
      output_tokens: metadata[:output_tokens],
      cache_creation_input_tokens: metadata[:cache_creation_input_tokens],
      cache_read_input_tokens: metadata[:cache_read_input_tokens]
    )
  end

  def opencode_command(workspace_path:, prompt:, model:, resume_session_id:)
    cmd = [
      "opencode", "run",
      "--format", "json",
      "--dir", workspace_path,
      "--model", model,
      "--dangerously-skip-permissions"
    ]
    cmd += [ "--session", resume_session_id ] if resume_session_id.present?
    cmd << prompt
    cmd
  end

  def opencode_env(backend_config:, opencode_home:, config_path:)
    ProcessRunner.forwarded_env(
      AgentInvocation::ENV_FORWARD,
      extra: WorkspaceDependencyEnv.for(@workspace_path).merge(
        "HOME" => opencode_home,
        "OPENCODE_CONFIG" => config_path,
        "OPENCODE_CONFIG_DIR" => opencode_home,
        "OPENCODE_DISABLE_AUTOUPDATE" => "1",
        "OPENCODE_DISABLE_MODELS_FETCH" => "1",
        API_KEY_ENV => backend_config.api_key.presence
      )
    )
  end

  def opencode_config_json(backend_config, mcp_server)
    config = {
      "$schema" => CONFIG_SCHEMA,
      "model" => config_model(backend_config),
      "autoupdate" => false,
      "share" => "disabled",
      "enabled_providers" => [ provider_id(backend_config) ],
      "provider" => provider_config(backend_config)
    }
    config["mcp"] = mcp_config(mcp_server) if mcp_server
    config
  end

  def config_model(backend_config)
    "#{provider_id(backend_config)}/#{backend_config.model}"
  end

  def provider_id(backend_config)
    case backend_config.backend
    when "openai_api"
      "openai"
    when "azure_openai"
      "syrus-azure-openai"
    when "ollama"
      "ollama"
    else
      raise AgentProviders::ConfigurationError, "Unsupported OpenCode backend: #{backend_config.backend.inspect}"
    end
  end

  def provider_config(backend_config)
    id = provider_id(backend_config)
    provider = {
      id => {
        "models" => {
          backend_config.model => { "name" => backend_config.model }
        }
      }
    }

    case backend_config.backend
    when "openai_api"
      provider[id]["options"] = { "apiKey" => "{env:#{API_KEY_ENV}}" }
    when "azure_openai"
      provider[id].merge!(
        "npm" => "@ai-sdk/openai-compatible",
        "name" => "Syrus Azure OpenAI",
        "options" => {
          "baseURL" => backend_config.endpoint_url,
          "apiKey" => "{env:#{API_KEY_ENV}}"
        }
      )
    when "ollama"
      provider[id].merge!(
        "npm" => "@ai-sdk/openai-compatible",
        "name" => "Syrus Ollama",
        "options" => {
          "baseURL" => backend_config.endpoint_url
        }
      )
    end

    provider
  end

  def mcp_config(mcp_server)
    {
      "syrus-mcp-sidecar" => {
        "type" => "local",
        "command" => [ mcp_server.fetch(:command), *mcp_server.fetch(:args, []) ],
        "environment" => mcp_server.fetch(:env, {}).compact,
        "enabled" => true,
        "timeout" => 60_000
      }
    }
  end

  def process_event(line, log_sink)
    event = JSON.parse(line.strip)
    session_id = event["sessionID"] || event.dig("part", "sessionID")

    case event["type"]
    when "step_start"
      { session_id: session_id }
    when "text"
      text = event.dig("part", "text").to_s
      log_sink.call(text, kind: "assistant_text") if text.present?
      { session_id: session_id, final_text: text }
    when "tool_use"
      process_tool_use(event, log_sink)
      { session_id: session_id }
    when "step_finish"
      part = event["part"] || {}
      updates = usage_updates(part)
      if part["reason"].blank? || part["reason"] == "stop"
        log_sink.call(
          "[opencode result] reason=#{part['reason'] || 'complete'}, input_tokens=#{updates[:input_tokens]}, output_tokens=#{updates[:output_tokens]}, cost_usd=#{updates[:cost_usd]}",
          kind: "system"
        )
        { session_id: session_id, turns: 1, outcome: part["reason"].presence || "success", is_error: false }.merge(updates)
      else
        { session_id: session_id }.merge(updates)
      end
    when "error"
      message = event.dig("error", "data", "message") || event.dig("error", "message") || event.dig("error", "name") || "OpenCode error"
      log_sink.call("[opencode error] #{message}", kind: "system")
      { session_id: session_id, is_error: true, outcome: "error", final_text: message.to_s }
    else
      nil
    end
  rescue JSON::ParserError
    log_sink.call(line.chomp)
    nil
  end

  def process_tool_use(event, log_sink)
    part = event["part"] || {}
    state = part["state"] || {}
    tool = part["tool"].to_s.presence || "tool"
    input = state["input"] || {}
    output = state["output"] || state.dig("metadata", "output")
    status = state["status"].to_s.presence || "completed"

    log_sink.call(
      AgentEventAbbreviator.tool_use(tool, input, path_roots: [ @workspace_path ]),
      kind: "tool_call",
      tool_name: tool,
      tool_input: input
    )
    log_sink.call(
      AgentEventAbbreviator.tool_result(output.to_s),
      kind: "tool_result",
      tool_result_content: output.to_s,
      tool_result_error: status == "error",
      tool_use_id: part["callID"]
    ) if output.present?
  end

  def usage_updates(part)
    tokens = part["tokens"] || {}
    cache = tokens["cache"] || {}
    {
      cost_usd: part["cost"],
      input_tokens: tokens["input"],
      output_tokens: tokens["output"],
      cache_creation_input_tokens: cache["write"],
      cache_read_input_tokens: cache["read"]
    }.compact
  end

  def transcript_path_for(opencode_home, session_id)
    File.join(opencode_home, "syrus-transcripts", "#{session_id}.jsonl")
  end

  def write_transcript(path, session_id, transcript)
    return nil if transcript.blank?

    path = transcript_path_for(File.dirname(File.dirname(path)), session_id) if session_id.present?
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, transcript)
    path
  end

  def restore_resume_transcript(opencode_home, session_id, jsonl)
    return if session_id.blank? || jsonl.blank?

    path = transcript_path_for(opencode_home, session_id)
    return if File.exist?(path)

    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, jsonl)
  end
end
