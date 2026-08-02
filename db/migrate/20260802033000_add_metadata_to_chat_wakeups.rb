class AddMetadataToChatWakeups < ActiveRecord::Migration[8.1]
  def change
    add_column :chat_wakeups, :metadata, :json unless column_exists?(:chat_wakeups, :metadata)
  end
end
