class ChatScopedEventEvaluatorJob < ApplicationJob
  queue_as :chat

  limits_concurrency to: 1, group: ChatTurnJob::CONCURRENCY_GROUP, key: ->(_event_id, chat_session_id = nil) {
    "chat:#{chat_session_id || ChatScopedEvent.find_by(id: _event_id)&.chat_session_id}"
  }, duration: 15.minutes

  def perform(chat_scoped_event_id, chat_session_id = nil)
    event = ChatScopedEvent.includes(:chat_session).find_by(id: chat_scoped_event_id)
    return unless event
    return if chat_session_id.present? && event.chat_session_id != chat_session_id.to_i

    ChatEventEvaluator.new(event: event, chat_session: event.chat_session).call
  end
end
