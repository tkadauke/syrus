class ChatMessage < ApplicationRecord
  ROLES = %w[ user assistant tool_use tool_result system ].freeze

  belongs_to :chat_session
  belongs_to :proposal, class_name: "ChatProposal", optional: true

  after_create_commit :broadcast_to_chat

  validates :role, presence: true, inclusion: { in: ROLES }
  validate :content_is_present

  broadcasts_to ->(message) { "chat_session_#{message.chat_session_id}_messages" },
                inserts_by: :append,
                target: ->(message) { "chat_session_#{message.chat_session_id}_messages" }

  private

  def content_is_present
    errors.add(:content, "can't be blank") if content.nil?
  end

  def broadcast_to_chat
    broadcast_append_later_to(
      "chat_session_#{chat_session_id}_messages",
      target: "chat_session_#{chat_session_id}_messages",
      partial: "repositories/chats/message",
      locals: { message: self, repository: chat_session.repository }
    )
  end
end
