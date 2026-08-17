class AddConversationKindToChatSessions < ActiveRecord::Migration[8.1]
  def change
    unless column_exists?(:chat_sessions, :conversation_kind)
      add_column :chat_sessions, :conversation_kind, :string, default: "direct", null: false
    end
  end
end
