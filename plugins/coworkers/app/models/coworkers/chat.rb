class Coworkers::Chat < ApplicationRecord
  self.table_name = "coworker_chats"
  ROLES = %w[main side].freeze

  belongs_to :coworker, inverse_of: :coworker_chats
  belongs_to :chat_session
  validates :chat_session_id, uniqueness: true
  validates :role, inclusion: { in: ROLES }
  validates :coworker_id, uniqueness: { conditions: -> { where(role: "main") } }, if: :main?
  validate :chat_and_coworker_share_owner

  def main? = role == "main"

  private

  def chat_and_coworker_share_owner
    return if coworker.nil? || chat_session.nil?
    return if coworker.owner_user_id == chat_session.user_id

    errors.add(:chat_session, "must be owned by the coworker's owner")
  end
end
