class AddCodingRelayToChatSessions < ActiveRecord::Migration[8.1]
  def change
    add_column :chat_sessions, :coding_relay_address, :string unless column_exists?(:chat_sessions, :coding_relay_address)
    add_column :chat_sessions, :coding_relay_token, :string unless column_exists?(:chat_sessions, :coding_relay_token)
  end
end
