class ChatWorkspaceJob < ApplicationJob
  queue_as :chat
  limits_concurrency to: 1,
                     group: ChatTurnJob::CONCURRENCY_GROUP,
                     key: ->(chat_session_id, **) { "chat:#{chat_session_id}" }

  def perform(chat_session_id, action:)
    chat_session = ChatSession.find(chat_session_id)
    repository = chat_session.repository
    action = action.to_s

    case action
    when "refresh"
      raise ArgumentError, "chat session has no repository attachment" unless repository

      path = ChatWorkspace.refresh!(chat_session, repository)
      sha = GitRunner.new.run("rev-parse", "origin/#{repository.default_branch}", chdir: path.to_s).strip
      broadcast_system_message(chat_session, "Workspace refreshed: #{sha}.")
    when "reset"
      ChatWorkspace.reset!(chat_session)
      broadcast_system_message(chat_session, "Workspace reset.")
    else
      raise ArgumentError, "unknown chat workspace action: #{action}"
    end
  end

  private

  def broadcast_system_message(chat_session, text)
    ApplicationRecord.transaction do
      chat_session.update!(last_message_at: Time.current)
      chat_session.messages.create!(role: "system", content: { "text" => text })
    end
  end
end
