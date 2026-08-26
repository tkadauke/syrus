class AddSoftDeletionToChatSessions < ActiveRecord::Migration[8.1]
  def up
    add_column :chat_sessions, :deleted_at, :datetime unless column_exists?(:chat_sessions, :deleted_at)

    unless column_exists?(:chat_sessions, :deleted_by_user_id)
      add_reference :chat_sessions, :deleted_by_user, null: true
    end

    add_index :chat_sessions, :deleted_at unless index_exists?(:chat_sessions, :deleted_at)
  end

  def down
    remove_index :chat_sessions, :deleted_at if index_exists?(:chat_sessions, :deleted_at)
    remove_reference :chat_sessions, :deleted_by_user if column_exists?(:chat_sessions, :deleted_by_user_id)
    remove_column :chat_sessions, :deleted_at if column_exists?(:chat_sessions, :deleted_at)
  end
end
