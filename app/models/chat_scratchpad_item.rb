class ChatScratchpadItem < ApplicationRecord
  belongs_to :chat_session
  has_many :chat_file_attachments, as: :attachable, dependent: :nullify

  after_commit :broadcast_chat_controls
  after_commit -> { ChatFileAttachment.claim_for(self) }, on: %i[create update], if: :saved_change_to_content?

  validates :content, presence: true
  validate :draft_content_is_present

  scope :ordered, -> { order(:position, :id) }

  def draft_content
    ChatDraftContent.from_record(self)
  end

  def text
    draft_content.text
  end

  private

  def draft_content_is_present
    errors.add(:content, "can't be blank") unless draft_content.present?
  end

  def broadcast_chat_controls
    chat_session.broadcast_controls
  end
end
