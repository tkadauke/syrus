class ChatAttachment < ApplicationRecord
  ATTACHABLE_TYPES = %w[ Repository Epic Job Document ].freeze

  attr_accessor :suppress_header_broadcast

  belongs_to :chat_session
  belongs_to :attachable, polymorphic: true

  after_commit :broadcast_chat_session_header_update, on: [ :create, :destroy ]

  before_validation :set_attached_at

  validates :attached_at, presence: true
  validates :attachable_type, inclusion: { in: ATTACHABLE_TYPES }
  validates :attachable_id, uniqueness: { scope: [ :chat_session_id, :attachable_type ] }
  validate :attachable_belongs_to_chat_user

  private

  def broadcast_chat_session_header_update
    return if suppress_header_broadcast

    chat_session.reload.broadcast_app_header_update unless chat_session.destroyed?
  end

  def set_attached_at
    self.attached_at ||= Time.current
  end

  def attachable_belongs_to_chat_user
    return unless chat_session && attachable
    return unless attachable.respond_to?(:user_id)

    # This guards all attachment paths, including attached Epics consumed by
    # chat MCP tools, against attaching another user's resource by raw id.
    # Repositories are globally unique and access-controlled via memberships;
    # a user may attach any repository where they are a member.
    if attachable.is_a?(Repository)
      return if attachable.repository_memberships.exists?(user_id: chat_session.user_id)
      return if attachable.user_id == chat_session.user_id
    end

    errors.add(:attachable, "must belong to the chat session user") if attachable.user_id != chat_session.user_id
  end
end
