class ChatParticipant < ApplicationRecord
  ROLES = %w[owner member].freeze

  belongs_to :chat_session
  belongs_to :user

  validates :role, inclusion: { in: ROLES }
  validates :user_id, uniqueness: { scope: :chat_session_id }
  validates :joined_at, presence: true

  before_validation :set_joined_at, on: :create

  private

  def set_joined_at
    self.joined_at ||= Time.current
  end
end
