class ChatSpendEntry < ApplicationRecord
  belongs_to :chat_session
  belongs_to :user

  validates :incurred_at, presence: true
  validates :agent_provider, presence: true, inclusion: { in: -> { User.chat_providers } }
  validates :cost_usd, numericality: { greater_than: 0 }
end
