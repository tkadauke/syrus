class ChatAttachment < ApplicationRecord
  ATTACHABLE_TYPES = %w[ Repository Epic Job Document RepositoryDocument ].freeze

  belongs_to :chat_session
  belongs_to :attachable, polymorphic: true

  before_validation :set_attached_at

  validates :attached_at, presence: true
  validates :attachable_type, inclusion: { in: ATTACHABLE_TYPES }
  validates :attachable_id, uniqueness: { scope: [ :chat_session_id, :attachable_type ] }
  validate :attachable_belongs_to_chat_user

  private

  def set_attached_at
    self.attached_at ||= Time.current
  end

  def attachable_belongs_to_chat_user
    return unless chat_session && attachable
    return unless attachable.respond_to?(:user_id)

    errors.add(:attachable, "must belong to the chat session user") if attachable.user_id != chat_session.user_id
  end
end
