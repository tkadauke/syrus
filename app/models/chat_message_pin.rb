class ChatMessagePin < ApplicationRecord
  belongs_to :chat_message, inverse_of: :pins

  after_create_commit :broadcast_upsert
  after_destroy_commit :broadcast_remove

  private

  def broadcast_upsert
    broadcast_app_event("upsert_pin", pin: { id: id, chat_message_id: chat_message_id })
  end

  def broadcast_remove
    broadcast_app_event("remove_pin", pin: { id: id, chat_message_id: chat_message_id })
  end

  def broadcast_app_event(action, **payload)
    chat = chat_message.chat_session
    chat.send(
      :broadcast_to_participants,
      type: "updated",
      resource: "chat",
      id: chat.id,
      changed: [ "pins" ],
      payload: { action: action }.merge(payload)
    )
  end
end
