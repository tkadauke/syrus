class AddChatModelToChatSessions < ActiveRecord::Migration[8.1]
  def change
    add_column :chat_sessions, :chat_model, :string unless column_exists?(:chat_sessions, :chat_model)
  end
end
