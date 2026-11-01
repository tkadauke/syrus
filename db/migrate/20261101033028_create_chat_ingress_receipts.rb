class CreateChatIngressReceipts < ActiveRecord::Migration[8.1]
  def change
    add_column :chat_messages, :client_idempotency_key, :string
    add_column :chat_queued_messages, :client_idempotency_key, :string
    add_index :chat_messages, [ :sender_user_id, :client_idempotency_key ], unique: true, where: "client_idempotency_key IS NOT NULL", name: "idx_chat_messages_sender_idempotency"
    add_index :chat_queued_messages, [ :chat_session_id, :client_idempotency_key ], unique: true, where: "client_idempotency_key IS NOT NULL", name: "idx_chat_queued_messages_session_idempotency"

    create_table :chat_ingress_receipts do |t|
      t.references :sender_user, null: false, foreign_key: { to_table: :users }
      t.string :idempotency_key, null: false
      t.string :operation, null: false
      t.string :payload_digest, null: false
      t.references :chat_session, foreign_key: { on_delete: :nullify }
      t.references :chat_message, foreign_key: { on_delete: :nullify }
      t.references :chat_queued_message, foreign_key: { on_delete: :nullify }
      t.integer :response_status
      t.json :response_body
      t.timestamps
    end

    add_index :chat_ingress_receipts, [ :sender_user_id, :idempotency_key ], unique: true, name: "idx_chat_ingress_receipts_sender_key"
  end
end
