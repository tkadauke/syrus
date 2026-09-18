class ChatTurnAutoRetryAttempt < ApplicationRecord
  MAX_ATTEMPTS = AutoRetryAttempt::MAX_ATTEMPTS
  BACKOFFS = AutoRetryAttempt::BACKOFFS

  belongs_to :chat_session
  belongs_to :root_user_message, class_name: "ChatMessage"
  belongs_to :user_message, class_name: "ChatMessage"
  belongs_to :retry_message, class_name: "ChatMessage", optional: true

  validates :attempt_number, presence: true, numericality: { only_integer: true, greater_than: 0 }
  validates :scheduled_at, presence: true

  scope :active, -> { where(exhausted_at: nil, skipped_reason: nil) }
  scope :due, ->(now = Time.current) { active.where(performed_at: nil).where(scheduled_at: ..now) }
  scope :unskipped, -> { where(skipped_reason: nil) }

  def self.backoff_for(attempt_number)
    BACKOFFS[attempt_number - 1] || BACKOFFS.last
  end
end
