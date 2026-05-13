class ChatSession < ApplicationRecord
  belongs_to :repository
  belongs_to :user

  has_many :messages, class_name: "ChatMessage", dependent: :destroy
  has_many :proposals, class_name: "ChatProposal", dependent: :destroy
end
