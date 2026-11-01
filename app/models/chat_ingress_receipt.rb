class ChatIngressReceipt < ApplicationRecord
  belongs_to :sender_user, class_name: "User"
  belongs_to :chat_session, optional: true
  belongs_to :chat_message, optional: true
  belongs_to :chat_queued_message, optional: true

  validates :idempotency_key, :operation, :payload_digest, presence: true
end
