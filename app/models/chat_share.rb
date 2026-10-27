class ChatShare < ApplicationRecord
  belongs_to :chat_session
  belongs_to :target, polymorphic: true
  belongs_to :shared_by_user, class_name: "User"

  validates :target_type, inclusion: { in: [ "User" ] }
  validate :shared_by_user_owns_chat
  validate :target_is_not_chat_owner
  validate :target_is_not_participant

  after_create_commit :notify_recipient

  private

  def shared_by_user_owns_chat
    errors.add(:shared_by_user, "must own the chat") unless chat_session&.user_id == shared_by_user_id
  end

  def target_is_not_chat_owner
    errors.add(:target, "already owns the chat") if target_type == "User" && chat_session&.user_id == target_id
  end

  def target_is_not_participant
    return unless target_type == "User" && chat_session

    errors.add(:target, "is already a participant") if chat_session.chat_participants.exists?(user_id: target_id)
  end

  def notify_recipient
    NotificationService.create_for(
      user: target,
      kind: "chat_mention",
      repository: chat_session.repository,
      actor: shared_by_user,
      body: "#{shared_by_user.display_name} shared a chat with you.",
      target_path: "/chats/#{chat_session_id}",
      dedupe_key: "chat-share:#{id}:user:#{target_id}"
    )
  end
end
