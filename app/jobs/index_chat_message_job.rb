class IndexChatMessageJob < ApplicationJob
  queue_as :default

  def perform(message_id)
    message = ChatMessage.find_by(id: message_id)
    return unless message

    ChatMessageSearchIndex.insert(message) if ChatMessageSearchIndex.indexable?(message)
  end
end
