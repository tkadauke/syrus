class ChatQueuedMessage < ApplicationRecord
  belongs_to :chat_session

  after_commit :broadcast_chat_controls

  validates :content, presence: true
  validate :text_is_present

  scope :pending, -> { where(delivered_at: nil) }

  def text
    content.is_a?(Hash) ? content["text"].to_s : content.to_s
  end

  private

  def text_is_present
    errors.add(:content, "can't be blank") if text.blank?
  end

  def broadcast_chat_controls
    chat_session.broadcast_controls
  end
end
