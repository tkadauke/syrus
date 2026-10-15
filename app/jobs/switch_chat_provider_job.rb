require "fileutils"
require "securerandom"

class SwitchChatProviderJob < ApplicationJob
  queue_as :chat

  limits_concurrency to: 1,
                     group: ChatTurnJob::CONCURRENCY_GROUP,
                     key: ->(chat_session_id, *) { "chat:#{chat_session_id}" },
                     duration: 30.minutes

  def perform(chat_session_id, provider)
    @chat = ChatSession.includes(:participants, :provider_session).find(chat_session_id)
    return if @chat.deleted?

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
    return if @chat.reload.deleted?

    new_session_id = SecureRandom.uuid
    workspace_path = ChatWorkspace.path_for(@chat).to_s
    jsonl = rehydrate_for(provider, new_session_id, workspace_path)
    return if @chat.reload.deleted?

    write_provider_session_to_disk!(workspace_path, new_session_id, jsonl) if provider == "claude" && jsonl.present?

    ApplicationRecord.transaction do
      @chat.lock!
      return if @chat.deleted?

      previous_provider = @chat.effective_chat_provider
      @chat.update!(chat_provider: provider)

      if @chat.messages.exists?
        attrs = { provider: provider, session_id: new_session_id, transcript_jsonl: jsonl }
        if @chat.provider_session
          @chat.provider_session.update!(attrs)
        else
          @chat.create_provider_session!(attrs)
        end
      end
      @chat.participants.each do |participant|
        App::ProviderAvailability.broadcast_changed(user: participant, provider: previous_provider) if previous_provider.present? && previous_provider != provider
        App::ProviderAvailability.broadcast_changed(user: participant, provider: provider)
      end
    end
  end

  def rehydrate_for(provider, session_id, workspace_path)
    return nil unless @chat.messages.exists?

    klass = ChatSessionRehydrator.for(provider)
    klass&.new(@chat, session_id: session_id, cwd: workspace_path)&.call
  end

  def write_provider_session_to_disk!(workspace_path, session_id, jsonl)
    path = ProviderSession.canonical_path_for(
      home: ENV.fetch("HOME"),
      cwd: workspace_path,
      session_id: session_id
    )
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, jsonl)
  end
end
