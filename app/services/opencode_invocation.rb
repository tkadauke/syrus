require "fileutils"
require "json"
require "tmpdir"

class OpencodeInvocation
  DEFAULT_TIMEOUT_SECONDS = AgentInvocation::DEFAULT_TIMEOUT_SECONDS
  MCP_STARTUP_TIMEOUT_SECONDS = 60
  MCP_TOOL_TIMEOUT_SECONDS = 60

  # Default Ollama base URL — override via SYRUS_OLLAMA_URL.
  DEFAULT_OLLAMA_URL = "http://localhost:11434".freeze
  DEFAULT_OLLAMA_MODEL = "qwen2.5-coder:32b".freeze

  def initialize(workspace_path, prompt:, model:,
                 log_sink: ->(*, **) { },
                 runner: nil,
                 timeout: DEFAULT_TIMEOUT_SECONDS,
                 opencode_home: nil,
                 mcp_server: nil,
                 resume_session_id: nil)
    @workspace_path = workspace_path.to_s
    @prompt = prompt
    @model = model.presence || ENV.fetch("SYRUS_OPENCODE_MODEL", DEFAULT_OLLAMA_MODEL)
    @log_sink = log_sink
    @runner = runner || method(:default_runner)
    @timeout = timeout
    @opencode_home = opencode_home&.to_s
    @mcp_server = mcp_server
    @resume_session_id = resume_session_id
  end

  def run
    @runner.call(
      workspace_path: @workspace_path,
      prompt: @prompt,
      model: @model,
      log_sink: @log_sink,
      timeout: @timeout,
      opencode_home: @opencode_home,
      mcp_server: @mcp_server,
      resume_session_id: @resume_session_id
    )
  end

  private

  def default_runner(workspace_path:, prompt:, model:, log_sink:, timeout:,
                     opencode_home:, mcp_server: nil, resume_session_id: nil)
    opencode_home = opencode_home.presence || File.join(Dir.home, ".opencode-syrus")
    FileUtils.mkdir_p(opencode_home)
    write_config(opencode_home, model, mcp_server)

    env = opencode_env(opencode_home: opencode_home)
    cmd = opencode_command(workspace_path: workspace_path,
                           prompt: prompt,
                           model: model,
                           resume_session_id: resume_session_id)

    metadata = {
      session_id: nil,
      is_error: false,
      outcome: nil,
      final_text: nil,
      turns: nil
    }
    transcript_lines = []
    current_run = Thread.current[:syrus_current_run]

    runner_result = ProcessRunner.new(
      env: env,
      command: cmd,
      chdir: workspace_path,
      timeout: timeout,
      silent_timeout: AgentInvocation::SILENT_TIMEOUT_SECONDS,
      kind: "agent",
      run: current_run,
      workflow: current_run&.workflow,
      on_output_line: ->(line) do
        transcript_lines << line
        update = process_event(line, log_sink)
        metadata.merge!(update.compact) if update
      end
    ).run

    AgentInvocation::Result.new(
      turns: metadata[:turns],
      exit_status: runner_result.exit_status,
      timed_out: runner_result.timed_out || runner_result.silent_timed_out,
      is_error: metadata[:is_error],
      outcome: metadata[:outcome],
      final_text: metadata[:final_text],
      session_id: metadata[:session_id],
      transcript_jsonl: transcript_lines.join("\n").presence
    )
  end

  def opencode_command(workspace_path:, prompt:, model:, resume_session_id:)
    cmd = [
      "opencode", "run", prompt,
      "--format", "json",
      "--model", "ollama/#{model}",
      "--dir", workspace_path,
      "--dangerously-skip-permissions"
    ]
    cmd += [ "--session", resume_session_id ] if resume_session_id.present?
    cmd
  end

  def opencode_env(opencode_home:)
    ollama_url = ENV.fetch("SYRUS_OLLAMA_URL", DEFAULT_OLLAMA_URL)
    ProcessRunner.forwarded_env(
      AgentInvocation::ENV_FORWARD,
      extra: WorkspaceDependencyEnv.for(@workspace_path).merge(
        "OPENCODE_HOME" => opencode_home,
        "SYRUS_OLLAMA_URL" => ollama_url
      )
    )
  end

  def write_config(opencode_home, model, mcp_server)
    FileUtils.mkdir_p(opencode_home)
    config = build_config(model, mcp_server)
    File.write(File.join(opencode_home, "opencode.jsonc"), JSON.pretty_generate(config))
  end

  def build_config(model, mcp_server)
    ollama_url = ENV.fetch("SYRUS_OLLAMA_URL", DEFAULT_OLLAMA_URL)
    config = {
      "$schema" => "https://opencode.ai/config.json",
      "provider" => {
        "ollama" => {
          "id" => "openai",
          "name" => "Ollama",
          "options" => {
            "baseURL" => "#{ollama_url}/v1",
            "apiKey" => "ollama"
          },
          "models" => {
            model => {
              "name" => model,
              "tool_call" => true
            }
          }
        }
      }
    }

    if mcp_server
      env = mcp_server.fetch(:env, {}).compact
      config["mcp"] = {
        "syrus-mcp-sidecar" => {
          "type" => "local",
          "command" => mcp_server.fetch(:command),
          "args" => mcp_server.fetch(:args, [])
        }.merge(env.any? ? { "environment" => env } : {})
      }
    end

    config
  end

  def process_event(line, log_sink)
    event = JSON.parse(line.strip)
    session_id = event["sessionID"]

    case event["type"]
    when "step_start"
      { session_id: session_id }
    when "text"
      text = event.dig("part", "text").to_s
      log_sink.call(text, kind: "assistant_text") if text.present?
      { session_id: session_id, final_text: text, turns: 1, outcome: "success" }
    when "tool_use"
      tool = event.dig("part", "toolName") || event.dig("part", "tool") || "unknown"
      log_sink.call("[opencode tool] #{tool}", kind: "tool_call")
      { session_id: session_id }
    when "tool_result"
      tool = event.dig("part", "toolName") || event.dig("part", "tool") || "unknown"
      log_sink.call("[opencode tool] #{tool} done", kind: "tool_result")
      { session_id: session_id }
    when "error"
      message = event.dig("error", "data", "message") || event.dig("error", "message") || "error"
      log_sink.call("[opencode error] #{message}", kind: "system")
      { session_id: session_id, is_error: true, outcome: "error", final_text: message.to_s }
    else
      { session_id: session_id }.compact
    end
  rescue JSON::ParserError
    log_sink.call(line.chomp)
    nil
  end
end
