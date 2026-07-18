class AddProvenanceToChatMemories < ActiveRecord::Migration[8.1]
  def up
    add_column :chat_memories, :source_type, :string unless column_exists?(:chat_memories, :source_type)
    add_column :chat_memories, :source_id, :bigint unless column_exists?(:chat_memories, :source_id)
    add_column :chat_memories, :author, :string unless column_exists?(:chat_memories, :author)
    add_column :chat_memories, :confidence, :float unless column_exists?(:chat_memories, :confidence)
    add_column :chat_memories, :last_verified_at, :datetime unless column_exists?(:chat_memories, :last_verified_at)
    add_column :chat_memories, :expires_at, :datetime unless column_exists?(:chat_memories, :expires_at)
    add_column :chat_memories, :visibility, :string unless column_exists?(:chat_memories, :visibility)
  end

  def down
    remove_column :chat_memories, :visibility if column_exists?(:chat_memories, :visibility)
    remove_column :chat_memories, :expires_at if column_exists?(:chat_memories, :expires_at)
    remove_column :chat_memories, :last_verified_at if column_exists?(:chat_memories, :last_verified_at)
    remove_column :chat_memories, :confidence if column_exists?(:chat_memories, :confidence)
    remove_column :chat_memories, :author if column_exists?(:chat_memories, :author)
    remove_column :chat_memories, :source_id if column_exists?(:chat_memories, :source_id)
    remove_column :chat_memories, :source_type if column_exists?(:chat_memories, :source_type)
  end
end
