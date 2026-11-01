require "rails_helper"

RSpec.describe ChatIngressReceipt do
  let(:user) { Factories.user }

  it "enforces one durable claim per sender and idempotency key" do
    attributes = {
      sender_user: user,
      idempotency_key: SecureRandom.uuid,
      operation: "message:1",
      payload_digest: "digest"
    }
    described_class.create!(attributes)

    expect { described_class.create!(attributes) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "allows different senders to use the same idempotency key" do
    key = SecureRandom.uuid
    described_class.create!(sender_user: user, idempotency_key: key, operation: "create", payload_digest: "digest")

    expect {
      described_class.create!(sender_user: Factories.user, idempotency_key: key, operation: "create", payload_digest: "digest")
    }.to change(described_class, :count).by(1)
  end

  it "has the unique database indexes that arbitrate receipt, message, and queue races" do
    receipt_index = described_class.connection.indexes(:chat_ingress_receipts).find { |index| index.name == "idx_chat_ingress_receipts_sender_key" }
    message_index = described_class.connection.indexes(:chat_messages).find { |index| index.name == "idx_chat_messages_sender_idempotency" }
    queued_index = described_class.connection.indexes(:chat_queued_messages).find { |index| index.name == "idx_chat_queued_messages_session_idempotency" }

    expect(receipt_index).to have_attributes(unique: true, columns: %w[sender_user_id idempotency_key])
    expect(message_index).to have_attributes(unique: true, columns: %w[sender_user_id client_idempotency_key])
    expect(queued_index).to have_attributes(unique: true, columns: %w[chat_session_id client_idempotency_key])
  end
end
