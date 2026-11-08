class ChatFileAttachment < ApplicationRecord
  ATTACHABLE_TYPES = %w[ChatMessage ChatQueuedMessage ChatScratchpadItem].freeze

  belongs_to :chat_session
  belongs_to :attachable, polymorphic: true, optional: true
  has_one_attached :file, dependent: :purge

  validates :name, :mime_type, :checksum, presence: true
  validates :byte_size, numericality: { greater_than_or_equal_to: 0 }
  validates :attachable_type, inclusion: { in: ATTACHABLE_TYPES }, allow_nil: true
  validate :attachable_belongs_to_chat_session
  before_validation :copy_blob_metadata

  def self.claim_for(owner)
    ids = Array(owner.content.is_a?(Hash) ? owner.content["attachments"] : nil).filter_map do |attributes|
      attributes["id"] || attributes[:id] if attributes.respond_to?(:[])
    end
    owner.chat_session.chat_file_attachments.where(id: ids).update_all(attachable_type: owner.class.polymorphic_name, attachable_id: owner.id) if ids.any?
  end

  private

  def copy_blob_metadata
    return unless file.attached?
    self.name = ChatAttachmentPolicy.sanitize_filename(name.presence || file.filename.to_s)
    self.mime_type = file.blob.content_type.to_s
    self.byte_size = file.blob.byte_size
    self.checksum = file.blob.checksum
  end

  def attachable_belongs_to_chat_session
    return unless attachable && attachable.chat_session_id != chat_session_id
    errors.add(:attachable, "must belong to the chat session")
  end
end
