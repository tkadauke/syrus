require "tempfile"

class ChatTurnJob < ApplicationJob
  CONCURRENCY_GROUP = "repository_chat"

  queue_as :runs
  discard_on StandardError

  limits_concurrency to: 1, group: CONCURRENCY_GROUP, key: ->(chat_session_id, *) {
    chat_session = ChatSession.find(chat_session_id)
    "chat:#{chat_session.repository_id}"
  }, duration: 30.minutes

  class << self
    attr_accessor :agent_runner
  end

  SIDECAR_ENV_FORWARD = AgentProviders::Base::SIDECAR_ENV_FORWARD

  def perform(chat_session_id, user_message_id)
    @chat = ChatSession.includes(:repository, :user).find(chat_session_id)
    @user_message = @chat.messages.find(user_message_id)
    @turn_started_at = Time.current
    @cancelled = false

    @chat.update!(stop_requested_at: nil)

    if @chat.user.claude_oauth_token.blank?
      create_message!("system", text: "Claude credentials are missing. Add a Claude OAuth token in Credentials, then send another message.")
      touch_chat!
      return
    end

    workspace_path = ensure_workspace!
    parent_session_id = @chat.claude_session&.session_id

    result = with_chat_mcp_config do |mcp_config|
      AgentInvocation.new(
        workspace_path,
        prompt: prompt_for(parent_session_id),
        oauth_token: @chat.user.claude_oauth_token,
        log_sink: method(:record_agent_event),
        runner: self.class.agent_runner,
        max_turns: nil,
        mcp_config: mcp_config,
        resume_session_id: parent_session_id,
        stop_requested: method(:stop_requested?)
      ).run
    end

    capture_session!(result) if result
    increment_usage!(result) if result
    touch_chat!
  end

  private

  def ensure_workspace!
    path = ChatWorkspace.path_for(@chat.repository)
    first_clone = !path.exist?

    create_message!("system", text: "Cloning #{@chat.repository.slug}...") if first_clone
    ChatWorkspace.ensure!(@chat.repository).tap do
      create_message!("system", text: "Clone ready.") if first_clone
    end
  end

  def prompt_for(parent_session_id)
    user_text = @user_message.content["text"].to_s
    return user_text if parent_session_id.present?

    [ Prompts::ChatSystem.new(repository: @chat.repository).to_s, user_text ].join("\n\n")
  end

  def with_chat_mcp_config
    Tempfile.create([ "syrus-chat-mcp-#{@chat.id}-", ".json" ]) do |f|
      f.write({
        mcpServers: {
          "syrus-chat-sidecar" => {
            type: "stdio",
            command: Rails.root.join("bin/syrus-chat-sidecar").to_s,
            env: sidecar_env,
            alwaysLoad: true
          }
        }
      }.to_json)
      f.flush
      yield f.path
    end
  end

  def sidecar_env
    ENV.slice(*SIDECAR_ENV_FORWARD).compact.merge("SYRUS_CHAT_SESSION_ID" => @chat.id.to_s)
  end

  def record_agent_event(chunk, kind: nil)
    role = case kind.to_s
    when "assistant_text" then "assistant"
    when "tool_call" then "tool_use"
    when "tool_result" then "tool_result"
    else "system"
    end

    create_message!(role, text: chunk.to_s)
  end

  def stop_requested?
    @chat.reload
    return false unless @chat.stop_requested_at && @chat.stop_requested_at > @turn_started_at

    unless @cancelled
      @cancelled = true
      create_message!("system", text: "Cancelled by operator.")
    end
    true
  end

  def create_message!(role, content)
    @chat.messages.create!(role: role, content: content.stringify_keys)
  end

  def capture_session!(result)
    return if result.session_id.blank?

    transcript_jsonl = transcript_jsonl_for(result, workspace_path: ChatWorkspace.path_for(@chat.repository))
    attrs = {
      provider: "claude",
      session_id: result.session_id,
      transcript_jsonl: transcript_jsonl
    }

    if @chat.claude_session
      @chat.claude_session.update!(attrs)
    else
      @chat.create_claude_session!(attrs)
    end
  end

  def transcript_jsonl_for(result, workspace_path:)
    return result.transcript_jsonl if result.transcript_jsonl.present?
    return File.read(result.transcript_path) if result.transcript_path.present? && File.exist?(result.transcript_path)
    return unless result.session_id.to_s.match?(AgentProviders::Claude::SESSION_ID_PATTERN)

    path = ClaudeSession.canonical_path_for(
      home: ENV.fetch("HOME"),
      cwd: workspace_path,
      session_id: result.session_id
    )
    File.read(path) if File.exist?(path)
  end

  def increment_usage!(result)
    input_tokens = result.input_tokens.to_i
    output_tokens = result.output_tokens.to_i
    return if input_tokens.zero? && output_tokens.zero?

    @chat.increment!(:cumulative_input_tokens, input_tokens) if input_tokens.positive?
    @chat.increment!(:cumulative_output_tokens, output_tokens) if output_tokens.positive?
  end

  def touch_chat!
    @chat.update!(last_message_at: Time.current)
  end
end
