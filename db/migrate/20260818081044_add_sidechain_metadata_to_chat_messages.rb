class AddSidechainMetadataToChatMessages < ActiveRecord::Migration[8.1]
  def up
    unless column_exists?(:chat_messages, :sidechain)
      add_column :chat_messages, :sidechain, :boolean
    end
    execute "UPDATE chat_messages SET sidechain = FALSE WHERE sidechain IS NULL"
    change_column_null :chat_messages, :sidechain, false, false
    change_column_default :chat_messages, :sidechain, false

    unless column_exists?(:chat_messages, :parent_tool_use_id)
      add_column :chat_messages, :parent_tool_use_id, :string
    end

    unless index_exists?(:chat_messages, [ :chat_session_id, :tool_use_id ])
      add_index :chat_messages, [ :chat_session_id, :tool_use_id ]
    end
  end

  def down
    if index_exists?(:chat_messages, [ :chat_session_id, :tool_use_id ])
      remove_index :chat_messages, [ :chat_session_id, :tool_use_id ]
    end
    remove_column :chat_messages, :parent_tool_use_id if column_exists?(:chat_messages, :parent_tool_use_id)
    remove_column :chat_messages, :sidechain if column_exists?(:chat_messages, :sidechain)
  end
end
