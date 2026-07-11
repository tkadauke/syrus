class AddLinkedChatToJobs < ActiveRecord::Migration[8.1]
  def up
    add_column :jobs, :linked_chat_id, :integer unless column_exists?(:jobs, :linked_chat_id)
    add_index :jobs, :linked_chat_id unless index_exists?(:jobs, :linked_chat_id)
    add_foreign_key :jobs, :chat_sessions, column: :linked_chat_id unless foreign_key_exists?(:jobs, column: :linked_chat_id)
  end

  def down
    remove_foreign_key :jobs, column: :linked_chat_id if foreign_key_exists?(:jobs, column: :linked_chat_id)
    remove_index :jobs, :linked_chat_id if index_exists?(:jobs, :linked_chat_id)
    remove_column :jobs, :linked_chat_id if column_exists?(:jobs, :linked_chat_id)
  end
end
