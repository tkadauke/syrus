class ChatBookmark < ApplicationRecord
  KINDS = %w[ topic epic_origin manual ].freeze

  belongs_to :chat_message, inverse_of: :bookmarks

  after_create_commit :broadcast_app_event

  enum :kind, {
    topic: "topic",
    epic_origin: "epic_origin",
    manual: "manual"
  }, validate: true

  validates :label, :kind, presence: true
  validates :kind, inclusion: { in: KINDS }

  def anchor_message_id
    message = chat_message
    return message.id if message.bookmarkable?

    session = message.chat_session
    session.messages
      .where(role: %w[user assistant])
      .where("id > ?", message.id)
      .order(:created_at, :id)
      .pick(:id) ||
      session.messages
        .where(role: %w[user assistant])
        .where("id < ?", message.id)
        .order(created_at: :desc, id: :desc)
        .pick(:id) ||
      message.id
  end

  private

  def broadcast_app_event
    chat = chat_message.chat_session
    AppEvents.broadcast(
      user: chat.user,
      type: "updated",
      resource: "chat",
      id: chat.id,
      changed: [ "bookmarks" ],
      payload: {
        action: "upsert_bookmark",
        bookmark: {
          id: id,
          label: label,
          chat_message_id: chat_message_id,
          anchor_message_id: anchor_message_id
        }
      }
    )
  end
end
