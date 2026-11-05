class Coworkers::WorkspaceSaveRetryJob < ApplicationJob
  queue_as :chat

  def perform(link_id, token)
    link = Coworkers::Chat.find_by(id: link_id)
    return unless link
    state = Coworkers::UnsavedWorkspace.new(link.chat_session)
    return unless state.begin_retry!(token)

    Coworkers::WorkspaceSaveRetry.for(link.unsaved_workspace_operation).perform(link)
  end
end
