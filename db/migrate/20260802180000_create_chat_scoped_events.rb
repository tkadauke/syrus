class CreateChatScopedEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_scoped_events do |t|
      t.references :chat_session, null: false, foreign_key: true
      t.references :repository, foreign_key: true
      t.references :job, foreign_key: true
      t.references :epic, foreign_key: true
      t.references :proposal, foreign_key: { to_table: :chat_proposals }
      t.references :chat_message, foreign_key: true
      t.string :source_kind, null: false
      t.string :delivery_state, null: false, default: "pending"
      t.string :dedupe_key
      t.json :payload, null: false
      t.datetime :delivered_at

      t.timestamps
    end

    unless index_exists?(:chat_scoped_events, [ :chat_session_id, :delivery_state, :created_at ], name: "idx_chat_scoped_events_delivery")
      add_index :chat_scoped_events, [ :chat_session_id, :delivery_state, :created_at ], name: "idx_chat_scoped_events_delivery"
    end

    unless index_exists?(:chat_scoped_events, [ :chat_session_id, :dedupe_key ], name: "idx_chat_scoped_events_dedupe")
      add_index :chat_scoped_events, [ :chat_session_id, :dedupe_key ], unique: true, name: "idx_chat_scoped_events_dedupe"
    end
  end
end
