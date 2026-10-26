class AddMentionsToChatMessages < ActiveRecord::Migration[8.1]
  def change
    add_column :chat_messages, :mentions, :json unless column_exists?(:chat_messages, :mentions)
  end
end
