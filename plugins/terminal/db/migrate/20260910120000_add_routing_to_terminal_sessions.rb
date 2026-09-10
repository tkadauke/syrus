class AddRoutingToTerminalSessions < ActiveRecord::Migration[8.1]
  def up
    ensure_bigint_reference(:terminal_sessions, :chat_session, null: true)
    add_column :terminal_sessions, :worker_hostname, :string unless column_exists?(:terminal_sessions, :worker_hostname)
    add_column :terminal_sessions, :worker_storage_key, :string unless column_exists?(:terminal_sessions, :worker_storage_key)
    add_column :terminal_sessions, :queue_name, :string unless column_exists?(:terminal_sessions, :queue_name)
    add_column :terminal_sessions, :workspace_kind, :string unless column_exists?(:terminal_sessions, :workspace_kind)

    add_index :terminal_sessions, :chat_session_id unless index_exists?(:terminal_sessions, :chat_session_id)
    add_index :terminal_sessions, :worker_storage_key unless index_exists?(:terminal_sessions, :worker_storage_key)
    add_index :terminal_sessions, :queue_name unless index_exists?(:terminal_sessions, :queue_name)
  end

  def down
    remove_index :terminal_sessions, :queue_name if index_exists?(:terminal_sessions, :queue_name)
    remove_index :terminal_sessions, :worker_storage_key if index_exists?(:terminal_sessions, :worker_storage_key)
    remove_index :terminal_sessions, :chat_session_id if index_exists?(:terminal_sessions, :chat_session_id)

    remove_column :terminal_sessions, :workspace_kind if column_exists?(:terminal_sessions, :workspace_kind)
    remove_column :terminal_sessions, :queue_name if column_exists?(:terminal_sessions, :queue_name)
    remove_column :terminal_sessions, :worker_storage_key if column_exists?(:terminal_sessions, :worker_storage_key)
    remove_column :terminal_sessions, :worker_hostname if column_exists?(:terminal_sessions, :worker_hostname)
    remove_column :terminal_sessions, :chat_session_id if column_exists?(:terminal_sessions, :chat_session_id)
  end

  private

  def ensure_bigint_reference(table, reference, null:)
    column_name = :"#{reference}_id"

    if column_exists?(table, column_name)
      column = connection.columns(table).find { |candidate| candidate.name == column_name.to_s }
      needs_bigint = column.type == :integer && column.limit != 8
      needs_nullability = column.null != null
      change_column table, column_name, :bigint, null: null if needs_bigint || needs_nullability
    else
      add_column table, column_name, :bigint, null: null unless column_exists?(table, column_name)
    end
  end
end
