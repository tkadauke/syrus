class CreateChatIngressReceipts < ActiveRecord::Migration[8.1]
  def change
    add_column :chat_messages, :client_idempotency_key, :string unless column_exists?(:chat_messages, :client_idempotency_key)
    add_column :chat_queued_messages, :client_idempotency_key, :string unless column_exists?(:chat_queued_messages, :client_idempotency_key)
    unless index_exists?(:chat_messages, [ :sender_user_id, :client_idempotency_key ], name: "idx_chat_messages_sender_idempotency")
      add_index :chat_messages, [ :sender_user_id, :client_idempotency_key ], unique: true, where: "client_idempotency_key IS NOT NULL", name: "idx_chat_messages_sender_idempotency"
    end
    unless index_exists?(:chat_queued_messages, [ :chat_session_id, :client_idempotency_key ], name: "idx_chat_queued_messages_session_idempotency")
      add_index :chat_queued_messages, [ :chat_session_id, :client_idempotency_key ], unique: true, where: "client_idempotency_key IS NOT NULL", name: "idx_chat_queued_messages_session_idempotency"
    end

    unless table_exists?(:chat_ingress_receipts)
      create_table :chat_ingress_receipts do |t|
        t.references :sender_user, null: false
        t.string :idempotency_key, null: false
        t.string :operation, null: false
        t.string :payload_digest, null: false
        t.references :chat_session
        t.references :chat_message
        t.references :chat_queued_message
        t.integer :response_status
        t.json :response_body
        t.timestamps
      end
    end

    unless index_exists?(:chat_ingress_receipts, [ :sender_user_id, :idempotency_key ], name: "idx_chat_ingress_receipts_sender_key")
      add_index :chat_ingress_receipts, [ :sender_user_id, :idempotency_key ], unique: true, name: "idx_chat_ingress_receipts_sender_key"
    end
  end
end
