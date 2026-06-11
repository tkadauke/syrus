class CreateChatQueuedMessages < ActiveRecord::Migration[8.1]
  def up
    create_table :chat_queued_messages, if_not_exists: true do |t|
      t.references :chat_session, null: false, foreign_key: true
      t.json :content, null: false
      t.datetime :delivered_at

      t.timestamps
    end

    add_index :chat_queued_messages, [ :chat_session_id, :delivered_at, :created_at, :id ], name: "idx_chat_queued_messages_pending_order" unless index_exists?(:chat_queued_messages, [ :chat_session_id, :delivered_at, :created_at, :id ], name: "idx_chat_queued_messages_pending_order")
  end

  def down
    drop_table :chat_queued_messages, if_exists: true
  end
end
