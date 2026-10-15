class AddHiddenAtToChatParticipants < ActiveRecord::Migration[8.1]
  INDEX_NAME = "idx_chat_participants_user_hidden_session"

  def up
    add_column :chat_participants, :hidden_at, :datetime unless column_exists?(:chat_participants, :hidden_at)
    execute <<~SQL.squish
      UPDATE chat_participants
      SET hidden_at = (
        SELECT chat_sessions.hidden_at
        FROM chat_sessions
        WHERE chat_sessions.id = chat_participants.chat_session_id
      )
      WHERE EXISTS (
        SELECT 1
        FROM chat_sessions
        WHERE chat_sessions.id = chat_participants.chat_session_id
          AND chat_sessions.hidden_at IS NOT NULL
      )
    SQL
    execute "UPDATE chat_sessions SET hidden_at = NULL WHERE hidden_at IS NOT NULL"
    add_index :chat_participants, [ :user_id, :hidden_at, :chat_session_id ], name: INDEX_NAME unless index_exists?(:chat_participants, name: INDEX_NAME)
  end

  def down
    remove_index :chat_participants, name: INDEX_NAME if index_exists?(:chat_participants, name: INDEX_NAME)
    remove_column :chat_participants, :hidden_at if column_exists?(:chat_participants, :hidden_at)
  end
end
