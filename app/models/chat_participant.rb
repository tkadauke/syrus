class ChatParticipant < ApplicationRecord
  ROLES = %w[owner member].freeze

  belongs_to :chat_session
  belongs_to :user

  validates :role, inclusion: { in: ROLES }
  validates :user_id, uniqueness: { scope: :chat_session_id }
  validates :joined_at, presence: true

  before_validation :set_initial_state, on: :create

  private

  def set_initial_state
    self.joined_at ||= Time.current
    self.hidden_at ||= chat_session&.hidden_at
  end
end
