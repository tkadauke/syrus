class AddModeToChatSessions < ActiveRecord::Migration[8.1]
  def up
    add_column :chat_sessions, :mode, :string, default: "planning", null: false unless column_exists?(:chat_sessions, :mode)
  end

  def down
    remove_column :chat_sessions, :mode if column_exists?(:chat_sessions, :mode)
  end
end
