require "fileutils"
require "json"
require "open3"

class CodexInvocation
  DEFAULT_TIMEOUT_SECONDS = AgentInvocation::DEFAULT_TIMEOUT_SECONDS
  CODEX_ENV_FORWARD = %w[
    HOME USER LOGNAME PATH TERM LANG LC_ALL LC_CTYPE TZ HOSTNAME TMPDIR SHELL
  ].freeze

  def initialize(workspace_path, prompt:, api_key: nil,
                 log_sink: ->(*, **) { },
                 runner: nil,
                 timeout: DEFAULT_TIMEOUT_SECONDS,
                 codex_home: nil,
                 mcp_server: nil,
                 resume_session_id: nil,
                 resume_transcript_jsonl: nil)
    @workspace_path = workspace_path.to_s
    @prompt = prompt
    @api_key = api_key
    @log_sink = log_sink
    @runner = runner || method(:default_runner)
    @timeout = timeout
    @codex_home = codex_home&.to_s
    @mcp_server = mcp_server
    @resume_session_id = resume_session_id
    @resume_transcript_jsonl = resume_transcript_jsonl
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
      resume_session_id: @resume_session_id,
      resume_transcript_jsonl: @resume_transcript_jsonl
    )
  end

  private

  def default_runner(workspace_path:, prompt:, api_key:, log_sink:, timeout:,
                     codex_home:, mcp_server: nil, resume_session_id: nil,
                     resume_transcript_jsonl: nil)
    codex_home = codex_home.presence || File.join(Dir.home, ".codex")
    FileUtils.mkdir_p(codex_home)
    write_config(codex_home, mcp_server)
    restore_resume_transcript(codex_home, resume_session_id, resume_transcript_jsonl)

    env = codex_env(api_key: api_key, codex_home: codex_home)
    cmd = codex_command(workspace_path: workspace_path,
                        prompt: prompt,
                        resume_session_id: resume_session_id)

    metadata = {
      turns: nil,
      is_error: false,
      outcome: nil,
      final_text: nil,
      session_id: nil,
      input_tokens: nil,
      output_tokens: nil,
      cache_creation_input_tokens: nil,
      cache_read_input_tokens: nil
    }
    timed_out = false
    result = nil

    Open3.popen2e(env, *cmd, chdir: workspace_path, unsetenv_others: true) do |stdin, output, wait_thread|
      stdin.close

      killer = Thread.new do
        sleep timeout
        timed_out = true
        kill_tree(wait_thread.pid)
      end

      output.each_line do |line|
        update = process_event(line, log_sink)
        metadata.merge!(update.compact) if update
      end

      killer.kill
      status = wait_thread.value
      transcript_path = rollout_path_for(codex_home, metadata[:session_id])
      result = AgentInvocation::Result.new(
        turns: metadata[:turns],
        exit_status: status.exitstatus,
        timed_out: timed_out,
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
    result
  end

  def codex_command(workspace_path:, prompt:, resume_session_id:)
    common = [ "--dangerously-bypass-approvals-and-sandbox", "--json" ]
    if resume_session_id.present?
      [ "codex", "exec", "resume", *common, resume_session_id, prompt ]
    else
      [ "codex", "exec", "--cd", workspace_path, *common, prompt ]
    end
  end

  def codex_env(api_key:, codex_home:)
    env = ENV.slice(*CODEX_ENV_FORWARD)
    env["CODEX_HOME"] = codex_home
    env["CODEX_API_KEY"] = api_key if api_key.present?
    env
  end

  def write_config(codex_home, mcp_server)
    FileUtils.mkdir_p(codex_home)
    File.write(File.join(codex_home, "config.toml"), codex_config_toml(mcp_server))
  end

  def codex_config_toml(mcp_server)
    lines = [
      'cli_auth_credentials_store = "file"',
      'approval_policy = "never"'
    ]

    return lines.join("\n") + "\n" unless mcp_server

    lines += [
      "",
      "[mcp_servers.syrus-mcp-sidecar]",
      "command = #{toml_string(mcp_server.fetch(:command))}",
      "args = #{toml_array(mcp_server.fetch(:args, []))}",
      "required = true",
      "startup_timeout_sec = 10",
      "tool_timeout_sec = 60"
    ]

    env = mcp_server.fetch(:env, {}).compact
    if env.any?
      lines << ""
      lines << "[mcp_servers.syrus-mcp-sidecar.env]"
      env.each do |key, value|
        lines << "#{key} = #{toml_string(value)}"
      end
    end

    lines.join("\n") + "\n"
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
      log_sink.call("[codex error] #{message}", kind: "system")
      { is_error: true, outcome: "turn_failed", final_text: message.to_s }
    when "error"
      message = event["message"] || event["error"] || "error"
      log_sink.call("[codex error] #{message}", kind: "system")
      { is_error: true, outcome: "error", final_text: message.to_s }
    when "item.started", "item.completed"
      process_item_event(event, log_sink)
    else
      nil
    end
  rescue JSON::ParserError
    log_sink.call(line.chomp)
    nil
  end

  def process_item_event(event, log_sink)
    item = event["item"] || {}
    status = item["status"] || event["type"].sub("item.", "")
    case item["type"]
    when "agent_message"
      text = item["text"].to_s
      log_sink.call(text, kind: "assistant_text") if text.present?
      { final_text: text }
    when "mcp_tool_call"
      tool = [ item["server"], item["tool"] ].compact.join(".")
      if item["error"]
        log_sink.call("[codex mcp] #{tool} #{status}: #{item['error']['message']}", kind: "tool_result")
      elsif item["result"]
        log_sink.call("[codex mcp] #{tool} #{status}", kind: "tool_result")
      else
        log_sink.call("[codex mcp] #{tool} #{status}", kind: "tool_call")
      end
      nil
    when "command_execution"
      command = item["command"].to_s
      log_sink.call("[codex command] #{command} #{status}", kind: "tool_call")
      nil
    when "file_change"
      log_sink.call("[codex file] #{item['path']} #{status}", kind: "system")
      nil
    else
      nil
    end
  end

  def rollout_path_for(codex_home, session_id)
    return nil if session_id.blank?
    Dir.glob(File.join(codex_home, "sessions", "**", "*#{session_id}.jsonl")).max_by { |path| File.mtime(path) }
  end

  def read_transcript(path)
    return nil if path.blank? || !File.exist?(path)
    File.read(path)
  end

  def restore_resume_transcript(codex_home, session_id, jsonl)
    return if session_id.blank? || jsonl.blank? || rollout_path_for(codex_home, session_id).present?

    dir = File.join(codex_home, "sessions", Time.now.utc.strftime("%Y/%m/%d"))
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "rollout-restored-#{session_id}.jsonl")
    File.write(path, jsonl)
  end

  def kill_tree(pid)
    Process.kill("TERM", pid)
    sleep 5
    Process.kill("KILL", pid) rescue nil
  rescue Errno::ESRCH
    # Already dead.
  end
end
