class AddChatSessionIdToSpawnedProcesses < ActiveRecord::Migration[8.1]
  def up
    add_column :spawned_processes, :chat_session_id, :integer unless column_exists?(:spawned_processes, :chat_session_id)
    add_index :spawned_processes, :chat_session_id, if_not_exists: true
  end

  def down
    remove_index :spawned_processes, :chat_session_id if index_exists?(:spawned_processes, :chat_session_id)
    remove_column :spawned_processes, :chat_session_id if column_exists?(:spawned_processes, :chat_session_id)
  end
end
