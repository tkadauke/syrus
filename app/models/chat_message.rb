class ChatMessage < ApplicationRecord
  ROLES = %w[ user assistant tool_use tool_result system ].freeze

  belongs_to :chat_session
  belongs_to :proposal, class_name: "ChatProposal", optional: true

  validates :role, presence: true, inclusion: { in: ROLES }
  validate :content_is_present

  private

  def content_is_present
    errors.add(:content, "can't be blank") if content.nil?
  end
end
