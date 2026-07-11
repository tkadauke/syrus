class AddLinkedChatIdToJobs < ActiveRecord::Migration[8.1]
  def up
    add_column :jobs, :linked_chat_id, :bigint unless column_exists?(:jobs, :linked_chat_id)
    add_index :jobs, :linked_chat_id unless index_exists?(:jobs, :linked_chat_id)
  end

  def down
    remove_index :jobs, :linked_chat_id if index_exists?(:jobs, :linked_chat_id)
    remove_column :jobs, :linked_chat_id if column_exists?(:jobs, :linked_chat_id)
  end
end
