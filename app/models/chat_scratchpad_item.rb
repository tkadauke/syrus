class ChatScratchpadItem < ApplicationRecord
  belongs_to :chat_session

  after_commit :broadcast_chat_controls

  validates :content, presence: true

  scope :ordered, -> { order(:position, :id) }

  private

  def broadcast_chat_controls
    chat_session.broadcast_controls
  end
end
