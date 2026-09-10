class AddRoutingToTerminalSessions < ActiveRecord::Migration[8.1]
  def up
    add_column :terminal_sessions, :chat_session_id, :integer unless column_exists?(:terminal_sessions, :chat_session_id)
    add_column :terminal_sessions, :worker_hostname, :string unless column_exists?(:terminal_sessions, :worker_hostname)
    add_column :terminal_sessions, :worker_storage_key, :string unless column_exists?(:terminal_sessions, :worker_storage_key)
    add_column :terminal_sessions, :queue_name, :string unless column_exists?(:terminal_sessions, :queue_name)
    add_column :terminal_sessions, :workspace_kind, :string unless column_exists?(:terminal_sessions, :workspace_kind)

    add_index :terminal_sessions, :chat_session_id unless index_exists?(:terminal_sessions, :chat_session_id)
    add_index :terminal_sessions, :worker_storage_key unless index_exists?(:terminal_sessions, :worker_storage_key)
    add_index :terminal_sessions, :queue_name unless index_exists?(:terminal_sessions, :queue_name)
    add_foreign_key :terminal_sessions, :chat_sessions unless foreign_key_exists?(:terminal_sessions, :chat_sessions)
  end

  def down
    remove_foreign_key :terminal_sessions, :chat_sessions if foreign_key_exists?(:terminal_sessions, :chat_sessions)
    remove_index :terminal_sessions, :queue_name if index_exists?(:terminal_sessions, :queue_name)
    remove_index :terminal_sessions, :worker_storage_key if index_exists?(:terminal_sessions, :worker_storage_key)
    remove_index :terminal_sessions, :chat_session_id if index_exists?(:terminal_sessions, :chat_session_id)

    remove_column :terminal_sessions, :workspace_kind if column_exists?(:terminal_sessions, :workspace_kind)
    remove_column :terminal_sessions, :queue_name if column_exists?(:terminal_sessions, :queue_name)
    remove_column :terminal_sessions, :worker_storage_key if column_exists?(:terminal_sessions, :worker_storage_key)
    remove_column :terminal_sessions, :worker_hostname if column_exists?(:terminal_sessions, :worker_hostname)
    remove_column :terminal_sessions, :chat_session_id if column_exists?(:terminal_sessions, :chat_session_id)
  end
end
