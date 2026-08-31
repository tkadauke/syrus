class ChatQueuedMessage < ApplicationRecord
  INTERNAL_ROLE_KEY = "_role".freeze
  PROMOTABLE_ROLES = %w[ user system ].freeze

  belongs_to :chat_session

  after_commit :broadcast_chat_controls

  validates :content, presence: true
  validate :text_is_present

  scope :pending, -> { where(delivered_at: nil) }

  def text
    draft_content.text
  end

  def draft_content
    ChatDraftContent.from_content(content)
  end

  # A message that carries media (a walkthrough video or file/image attachments)
  # is valid with no text — the media IS the message. Only a bodyless, medialess
  # message is blank.
  def carries_media?
    draft_content.media?
  end

  def promoted_role
    role = content.is_a?(Hash) ? content[INTERNAL_ROLE_KEY].to_s : ""
    PROMOTABLE_ROLES.include?(role) ? role : "user"
  end

  def promoted_content
    return content unless content.is_a?(Hash)

    content.except(INTERNAL_ROLE_KEY)
  end

  def visible_queued_draft?
    promoted_role == "user"
  end

  private

  def text_is_present
    return if carries_media?

    errors.add(:content, "can't be blank") if text.blank?
  end

  def broadcast_chat_controls
    chat_session.broadcast_controls
  end
end
