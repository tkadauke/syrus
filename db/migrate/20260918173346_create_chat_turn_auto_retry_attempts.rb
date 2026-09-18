class CreateChatTurnAutoRetryAttempts < ActiveRecord::Migration[8.1]
  def up
    create_table :chat_turn_auto_retry_attempts, if_not_exists: true do |t|
      t.references :chat_session, null: false, foreign_key: true
      t.references :root_user_message, null: false, foreign_key: { to_table: :chat_messages }
      t.references :user_message, null: false, foreign_key: { to_table: :chat_messages }
      t.references :retry_message, null: true, foreign_key: { to_table: :chat_messages }
      t.integer :attempt_number, null: false
      t.datetime :scheduled_at, null: false
      t.datetime :performed_at
      t.datetime :exhausted_at
      t.string :skipped_reason

      t.timestamps
    end

    unless index_exists?(:chat_turn_auto_retry_attempts, [ :chat_session_id, :root_user_message_id, :attempt_number ], name: "idx_chat_turn_auto_retries_budget")
      add_index :chat_turn_auto_retry_attempts,
                [ :chat_session_id, :root_user_message_id, :attempt_number ],
                name: "idx_chat_turn_auto_retries_budget",
                unique: true
    end

    unless index_exists?(:chat_turn_auto_retry_attempts, [ :scheduled_at, :performed_at, :skipped_reason ], name: "idx_chat_turn_auto_retries_due")
      add_index :chat_turn_auto_retry_attempts,
                [ :scheduled_at, :performed_at, :skipped_reason ],
                name: "idx_chat_turn_auto_retries_due"
    end
  end

  def down
    drop_table :chat_turn_auto_retry_attempts, if_exists: true
  end
end
