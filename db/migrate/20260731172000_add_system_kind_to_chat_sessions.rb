class AddSystemKindToChatSessions < ActiveRecord::Migration[8.1]
  def change
    add_column :chat_sessions, :system_kind, :string unless column_exists?(:chat_sessions, :system_kind)

    unless index_exists?(:chat_sessions, [ :user_id, :system_kind ], name: "index_chat_sessions_on_user_id_and_system_kind")
      add_index :chat_sessions, [ :user_id, :system_kind ], unique: true, name: "index_chat_sessions_on_user_id_and_system_kind"
    end
  end
end
