class Coworkers::Chat < ApplicationRecord
  self.table_name = "coworker_chats"
  ROLES = %w[main side].freeze

  belongs_to :coworker, inverse_of: :coworker_chats
  belongs_to :chat_session
  validates :chat_session_id, uniqueness: true
  validates :role, inclusion: { in: ROLES }
  validates :coworker_id, uniqueness: { conditions: -> { where(role: "main") } }, if: :main?

  def main? = role == "main"
end
