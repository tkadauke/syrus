class ChatShare < ApplicationRecord
  belongs_to :chat_session
  belongs_to :target, polymorphic: true
  belongs_to :shared_by_user, class_name: "User"

  validate :target_is_mentionable
  validate :shared_by_chat_owner

  private

  def target_is_mentionable
    errors.add(:target, "must be mentionable") unless target&.respond_to?(:handle) && target.handle.present?
  end

  def shared_by_chat_owner
    errors.add(:shared_by_user, "must own the chat") unless chat_session&.user_id == shared_by_user_id
  end
end
