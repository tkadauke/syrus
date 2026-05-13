class ChatWorkspaceJob < ApplicationJob
  queue_as :runs
  limits_concurrency to: 1,
                     group: ChatTurnJob::CONCURRENCY_GROUP,
                     key: ->(repository_id, **) { "chat:#{repository_id}" }

  def perform(repository_id, action:)
    repository = Repository.find(repository_id)
    action = action.to_s

    case action
    when "refresh"
      path = ChatWorkspace.refresh!(repository)
      sha = GitRunner.new.run("rev-parse", "origin/#{repository.default_branch}", chdir: path.to_s).strip
      broadcast_system_message(repository, "Workspace refreshed: #{sha}.")
    when "reset"
      ChatWorkspace.reset!(repository)
      broadcast_system_message(repository, "Workspace reset.")
    else
      raise ArgumentError, "unknown chat workspace action: #{action}"
    end
  end

  private

  def broadcast_system_message(repository, text)
    chat_session = repository.chat_sessions.order(last_message_at: :desc, created_at: :desc, id: :desc).first
    return unless chat_session

    ApplicationRecord.transaction do
      chat_session.update!(last_message_at: Time.current)
      chat_session.messages.create!(role: "system", content: { "text" => text })
    end
  end
end
