require "fileutils"
require "json"
require "securerandom"
require "tempfile"
require "tmpdir"

class ChatEventEvaluator
  DECISIONS = %w[no_op respond act].freeze
  MAX_MESSAGES = 10_000
  MAX_TRANSCRIPT_BYTES = 1.megabyte
  DEFAULT_TIMEOUT = 5.minutes
  DEFAULT_MAX_TURNS = 4

  MessageSnapshot = Data.define(:id, :role, :content, :created_at, :tool_name, :tool_use_id) do
    def canonical_content_format?
      case role
      when "assistant"
        content.is_a?(Array)
      when "tool_use", "tool_result"
        content.is_a?(Hash) && content.key?("type")
      else
        true
      end
    end
  end

  ContextClone = Data.define(:messages, :capped, :message_cap_applied, :byte_cap_applied,
                             :source_message_count, :cloned_message_count, :bytes)

  class << self
    attr_accessor :runner
  end

  def initialize(event:, chat_session:, runner: self.class.runner || ProviderRunner.new)
    @event = event
    @chat_session = chat_session
    @runner = runner
  end

  def call
    return @event.evaluator_result if @event.evaluator_completed?

    session_id = "chat-eval-#{SecureRandom.uuid}"
    @event.mark_evaluator_running!(session_id: session_id)

    clone = clone_context
    provider = @chat_session.effective_chat_provider
    transcript = transcript_for(provider, session_id, clone.messages)
    result = @runner.call(
      provider: provider,
      chat_session: @chat_session,
      prompt: prompt_for(clone),
      session_id: session_id,
      transcript_jsonl: transcript,
      timeout: DEFAULT_TIMEOUT,
      max_turns: DEFAULT_MAX_TURNS
    )

    payload = normalize_result(result, clone)
    @event.record_evaluator_result!(payload)
    payload
  rescue StandardError => e
    @event.record_evaluator_failure!("#{e.class}: #{e.message}") if @event&.persisted?
    raise
  end

  def clone_context
    source_count = @chat_session.messages.count
    relation = @chat_session.messages.order(:id)
    relation = relation.last(MAX_MESSAGES) if source_count > MAX_MESSAGES
    records = Array(relation)
    message_cap = source_count > MAX_MESSAGES
    snapshots = snapshot_messages(records)
    bytes = transcript_bytes(snapshots)
    byte_cap = false

    if bytes > MAX_TRANSCRIPT_BYTES
      byte_cap = true
      snapshots = cap_message_bytes(snapshots)
      bytes = transcript_bytes(snapshots)
    end

    ContextClone.new(
      messages: snapshots,
      capped: message_cap || byte_cap,
      message_cap_applied: message_cap,
      byte_cap_applied: byte_cap,
      source_message_count: source_count,
      cloned_message_count: snapshots.size,
      bytes: bytes
    )
  end

  private

  def snapshot_messages(records)
    records.map do |message|
      MessageSnapshot.new(
        id: message.id,
        role: message.role,
        content: deep_dup_json(message.content),
        created_at: message.created_at,
        tool_name: message.tool_name,
        tool_use_id: message.tool_use_id
      )
    end
  end

  def cap_message_bytes(messages)
    remaining = MAX_TRANSCRIPT_BYTES
    capped = messages.reverse.map do |message|
      content = capped_content(message, remaining)
      clone = MessageSnapshot.new(
        id: message.id,
        role: message.role,
        content: content,
        created_at: message.created_at,
        tool_name: message.tool_name,
        tool_use_id: message.tool_use_id
      )
      remaining -= message_bytes(clone)
      clone
    end
    capped.reverse
  end

  def capped_content(message, remaining)
    per_message = message.role == "tool_result" ? 4.kilobytes : 16.kilobytes
    limit = [ remaining, per_message ].min
    return omitted_content(message) if limit <= 0

    raw = JSON.generate(message.content)
    return message.content if raw.bytesize <= limit

    truncated = Mcp::Tools.truncate_text(raw, [ limit, 128 ].max)
    {
      "text" => "[truncated for disposable evaluator context]",
      "truncated_json" => truncated.fetch(:text),
      "original_bytes" => truncated.fetch(:bytes)
    }
  end

  def omitted_content(message)
    if message.role == "tool_result" && message.content.is_a?(Hash) && message.content["type"].present?
      message.content.merge("content" => "[omitted due to disposable evaluator transcript byte cap]")
    else
      { "text" => "[omitted due to disposable evaluator transcript byte cap]" }
    end
  end

  def transcript_bytes(messages)
    messages.sum { |message| message_bytes(message) }
  end

  def message_bytes(message)
    JSON.generate(
      role: message.role,
      content: message.content,
      tool_name: message.tool_name,
      tool_use_id: message.tool_use_id
    ).bytesize
  end

  def deep_dup_json(value)
    JSON.parse(JSON.generate(value))
  end

  def transcript_for(provider, session_id, messages)
    klass = ChatSessionRehydrator.for(provider)
    raise ChatProviders::ConfigurationError, "Unknown chat provider: #{provider.inspect}" unless klass

    kwargs = { session_id: session_id, messages: messages }
    kwargs[:cwd] = ChatWorkspace.path_for(@chat_session).to_s if provider == "claude"
    klass.new(@chat_session, **kwargs).call
  end

  def prompt_for(clone)
    Prompts::ChatEventEvaluator.new(
      chat_session: @chat_session,
      scoped_event: @event,
      context_summary: {
        capped: clone.capped,
        message_cap_applied: clone.message_cap_applied,
        byte_cap_applied: clone.byte_cap_applied,
        source_message_count: clone.source_message_count,
        cloned_message_count: clone.cloned_message_count,
        cloned_bytes: clone.bytes
      }
    ).to_s
  end

  def normalize_result(result, clone)
    raw = result.respond_to?(:final_text) ? result.final_text.to_s : result.to_s
    parsed = JSON.parse(extract_json(raw))
    decision = parsed["decision"].to_s
    decision = "no_op" unless DECISIONS.include?(decision)

    {
      "decision" => decision,
      "reason" => parsed["reason"].to_s,
      "urgency" => clamp_float(parsed["urgency"]),
      "confidence" => clamp_float(parsed["confidence"]),
      "handoff_prompt" => parsed["handoff_prompt"].to_s.presence,
      "context_clone" => {
        "capped" => clone.capped,
        "message_cap_applied" => clone.message_cap_applied,
        "byte_cap_applied" => clone.byte_cap_applied,
        "source_message_count" => clone.source_message_count,
        "cloned_message_count" => clone.cloned_message_count,
        "bytes" => clone.bytes
      }
    }.compact
  end

  def extract_json(raw)
    stripped = raw.to_s.strip
    return stripped if stripped.start_with?("{") && stripped.end_with?("}")

    match = stripped.match(/\{.*\}/m)
    raise JSON::ParserError, "evaluator did not return JSON" unless match

    match[0]
  end

  def clamp_float(value)
    numeric = Float(value, exception: false) || 0.0
    [ [ numeric, 0.0 ].max, 1.0 ].min
  end

  class ProviderRunner
    SIDECAR_ENV_FORWARD = AgentProviders::Base::SIDECAR_ENV_FORWARD

    def call(provider:, chat_session:, prompt:, session_id:, transcript_jsonl:, timeout:, max_turns:)
      Dir.mktmpdir("syrus-chat-event-evaluator") do |workspace_path|
        with_evaluator_mcp_config(chat_session) do |mcp_config|
          case provider
          when "claude"
            run_claude(chat_session, workspace_path, prompt, session_id, transcript_jsonl, mcp_config, timeout, max_turns)
          when "codex"
            run_codex(chat_session, workspace_path, prompt, session_id, transcript_jsonl, mcp_config, timeout)
          else
            raise ChatProviders::ConfigurationError, "Unknown chat provider: #{provider.inspect}"
          end
        end
      end
    end

    private

    def run_claude(chat_session, workspace_path, prompt, session_id, transcript_jsonl, mcp_config, timeout, max_turns)
      write_claude_transcript(workspace_path, session_id, transcript_jsonl)
      ClaudeInvocation.new(
        workspace_path,
        prompt: prompt,
        oauth_token: chat_session.user.claude_oauth_token,
        log_sink: ->(*) {},
        runner: ChatTurnJob.agent_runner,
        timeout: timeout,
        max_turns: max_turns,
        mcp_config: mcp_config,
        resume_session_id: session_id,
        disallowed_tools: ChatProviders::Claude::PLANNING_DISALLOWED_TOOLS,
        model: chat_session.chat_model.presence,
        effort_level: chat_session.chat_effort
      ).run
    ensure
      remove_claude_transcript(workspace_path, session_id)
    end

    def run_codex(chat_session, workspace_path, prompt, session_id, transcript_jsonl, mcp_config, timeout)
      codex_home = ChatWorkspace.agent_home_for(chat_session, "codex")
      codex_auth = CodexAuth.new(user: chat_session.user, codex_home: codex_home)
      auth = CodexAuth.with_refresh_lock(user: chat_session.user) { codex_auth.prepare! }
      CodexInvocation.new(
        workspace_path,
        prompt: prompt,
        api_key: auth.api_key,
        log_sink: ->(*) {},
        runner: ChatTurnJob.agent_runner,
        timeout: timeout,
        codex_home: codex_home,
        mcp_servers: mcp_servers_for(mcp_config),
        resume_session_id: session_id,
        resume_transcript_jsonl: transcript_jsonl
      ).run
    ensure
      codex_auth&.persist_updated_auth_json
      CodexUsageProbe.refresh_for(user: chat_session.user) if chat_session.user.codex_auth_mode == "chatgpt_login"
    end

    def with_evaluator_mcp_config(chat_session)
      Tempfile.create([ "syrus-chat-evaluator-mcp-#{chat_session.id}-", ".json" ]) do |file|
        file.write({
          mcpServers: {
            "syrus-chat-evaluator-sidecar" => {
              type: "stdio",
              command: Rails.root.join("bin/syrus-chat-sidecar").to_s,
              args: [ "--tier", "evaluator" ],
              env: sidecar_env(chat_session),
              alwaysLoad: true
            }
          }
        }.to_json)
        file.flush
        yield file.path
      end
    end

    def sidecar_env(chat_session)
      env = ENV.slice(*SIDECAR_ENV_FORWARD).compact
      if env["BUNDLE_PATH"].present?
        env["GEM_HOME"] ||= env["BUNDLE_PATH"]
        env["GEM_PATH"] ||= env["BUNDLE_PATH"]
      end
      env.merge(
        "SYRUS_CHAT_SESSION_ID" => chat_session.id.to_s,
        "SYRUS_CHAT_MCP_TOOL_TIER" => "evaluator",
        "SYRUS_CHAT_MCP_SERVER_NAME" => "syrus-chat-evaluator-sidecar"
      )
    end

    def mcp_servers_for(path)
      raw = JSON.parse(File.read(path))
      raw.fetch("mcpServers").transform_values do |server|
        {
          command: server.fetch("command"),
          args: Array(server["args"]),
          env: server.fetch("env", {}),
          required: server["alwaysLoad"] != false
        }
      end
    end

    def write_claude_transcript(workspace_path, session_id, transcript_jsonl)
      path = ClaudeSession.canonical_path_for(home: ENV.fetch("HOME"), cwd: workspace_path, session_id: session_id)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, transcript_jsonl)
    end

    def remove_claude_transcript(workspace_path, session_id)
      path = ClaudeSession.canonical_path_for(home: ENV.fetch("HOME"), cwd: workspace_path, session_id: session_id)
      FileUtils.rm_f(path)
    end
  end
end
