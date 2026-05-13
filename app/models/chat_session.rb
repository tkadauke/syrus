class ChatSession < ApplicationRecord
  belongs_to :repository
  belongs_to :user

  has_many :messages, class_name: "ChatMessage", dependent: :destroy
  has_many :proposals, class_name: "ChatProposal", dependent: :destroy

  validates :cumulative_input_tokens,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :cumulative_output_tokens,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 }
end
