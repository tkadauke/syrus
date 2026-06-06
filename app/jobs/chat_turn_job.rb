require "tempfile"

class ChatTurnJob < ApplicationJob
  CONCURRENCY_GROUP = "repository_chat"

  queue_as :chat
  discard_on StandardError

  limits_concurrency to: 1, group: CONCURRENCY_GROUP, key: ->(chat_session_id, *) {
    "chat:#{chat_session_id}"
  }, duration: 30.minutes

  class << self
    attr_accessor :agent_runner
  end

  SIDECAR_ENV_FORWARD = AgentProviders::Base::SIDECAR_ENV_FORWARD

  def perform(chat_session_id, user_message_id)
    @chat = ChatSession.includes(
      :user,
      :attached_repositories,
      :attached_jobs,
      :attached_repository_documents,
      attached_epics: [ :repository, { jobs: :repository } ]
    ).find(chat_session_id)
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
      ClaudeInvocation.new(
        workspace_path,
        prompt: prompt_for(parent_session_id),
        oauth_token: @chat.user.claude_oauth_token,
        log_sink: method(:record_agent_event),
        runner: self.class.agent_runner,
        max_turns: nil,
        mcp_config: mcp_config,
        resume_session_id: parent_session_id,
        stop_requested: method(:stop_requested?),
        process_started: ->(_process) { @chat.broadcast_controls }
      ).run
    end

    capture_session!(result) if result
    @chat.record_turn_usage!(result) if result
    touch_chat!
    @chat.broadcast_controls
  end

  private

  def ensure_workspace!
    ChatWorkspace.ensure_root!(@chat)
  end

  def prompt_for(parent_session_id)
    user_text = @user_message.content["text"].to_s
    snapshot = AgentEnvironmentSnapshot.for_chat(repository: @chat.repository, chat_session: @chat)
    return [ snapshot, user_text ].join("\n\n---\n\n") if parent_session_id.present?

    [ Prompts::ChatSystem.new(repository: @chat.repository, chat_session: @chat).to_s, user_text ].join("\n\n")
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

  def record_agent_event(chunk, kind: nil, tool_name: nil, tool_input: nil,
                         tool_result_content: nil, tool_result_error: nil,
                         tool_use_id: nil, **)
    case kind.to_s
    when "tool_call"
      # Persist the structured tool invocation. Abbreviation is the
      # presentation layer's job; storing the raw input keeps the data
      # tier honest and lets the view evolve without DB churn.
      @chat.messages.create!(
        role: "tool_use",
        tool_name: tool_name,
        content: { "input" => tool_input || {} }
      )
    when "tool_result"
      @chat.messages.create!(
        role: "tool_result",
        tool_name: tool_name,
        content: {
          "result" => tool_result_content,
          "is_error" => tool_result_error,
          "tool_use_id" => tool_use_id
        }.compact
      )
    when "assistant_text"
      create_message!("assistant", text: chunk.to_s)
    else
      create_message!("system", text: chunk.to_s)
    end
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

    transcript_jsonl = transcript_jsonl_for(result, workspace_path: ChatWorkspace.path_for(@chat))
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

    ClaudeSession.canonical_transcript_jsonl(
      home: ENV.fetch("HOME"),
      cwd: workspace_path,
      session_id: result.session_id
    )
  end

  def touch_chat!
    @chat.update!(last_message_at: Time.current)
  end
end
