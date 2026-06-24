class AddSoftDeletionToChatMemories < ActiveRecord::Migration[8.1]
  def up
    add_column :chat_memories, :deleted_at, :datetime unless column_exists?(:chat_memories, :deleted_at)

    unless column_exists?(:chat_memories, :deleted_by_user_id)
      add_reference :chat_memories, :deleted_by_user, null: true, foreign_key: { to_table: :users }
    end

    add_index :chat_memories, :deleted_at unless index_exists?(:chat_memories, :deleted_at)
  end

  def down
    remove_index :chat_memories, :deleted_at if index_exists?(:chat_memories, :deleted_at)
    remove_reference :chat_memories, :deleted_by_user, foreign_key: { to_table: :users } if column_exists?(:chat_memories, :deleted_by_user_id)
    remove_column :chat_memories, :deleted_at if column_exists?(:chat_memories, :deleted_at)
  end
end
