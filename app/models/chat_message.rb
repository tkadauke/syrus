class ChatMessage < ApplicationRecord
  belongs_to :chat_session
  belongs_to :proposal, class_name: "ChatProposal", optional: true

  validates :role, presence: true
  validates :content, presence: true
end
