require "fileutils"
require "securerandom"

class SwitchChatProviderJob < ApplicationJob
  queue_as :chat

  limits_concurrency to: 1,
                     group: ChatTurnJob::CONCURRENCY_GROUP,
                     key: ->(chat_session_id, *) { "chat:#{chat_session_id}" },
                     duration: 30.minutes

  def perform(chat_session_id, provider)
    @chat = ChatSession.includes(:user, :claude_session).find(chat_session_id)

    if @chat.turn_in_flight? || @chat.agent_busy?
      @chat.messages.create!(role: "system", content: { "text" => "Cannot switch provider while a turn is in progress." })
      @chat.broadcast_controls
      return
    end

    @chat.broadcast_controls(switching_provider: true)
    switch_to!(provider)
    @chat.reload
    @chat.broadcast_controls(switching_provider: false)
  rescue => e
    Rails.logger.error("[SwitchChatProviderJob] chat=#{chat_session_id} provider=#{provider} error=#{e.class}: #{e.message}")
    @chat&.broadcast_controls(switching_provider: false)
    raise
  end

  private

  def switch_to!(provider)
    new_session_id = SecureRandom.uuid
    workspace_path = ChatWorkspace.path_for(@chat).to_s
    jsonl = rehydrate_for(provider, new_session_id, workspace_path)

    write_claude_session_to_disk!(workspace_path, new_session_id, jsonl) if provider == "claude" && jsonl.present?

    ApplicationRecord.transaction do
      @chat.update!(chat_provider: provider)

      if @chat.messages.exists?
        attrs = { provider: provider, session_id: new_session_id, transcript_jsonl: jsonl }
        if @chat.claude_session
          @chat.claude_session.update!(attrs)
        else
          @chat.create_claude_session!(attrs)
        end
      end
    end
  end

  def rehydrate_for(provider, session_id, workspace_path)
    return nil unless @chat.messages.exists?

    case provider
    when "claude"
      ChatSessionRehydrator::Claude.new(@chat, session_id: session_id, cwd: workspace_path).call
    when "codex"
      ChatSessionRehydrator::Codex.new(@chat, session_id: session_id).call
    end
  end

  def write_claude_session_to_disk!(workspace_path, session_id, jsonl)
    path = ClaudeSession.canonical_path_for(
      home: ENV.fetch("HOME"),
      cwd: workspace_path,
      session_id: session_id
    )
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, jsonl)
  end
end
