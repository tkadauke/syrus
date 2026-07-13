class AddLocalModeToChatSessions < ActiveRecord::Migration[8.1]
  def up
    if column_exists?(:chat_sessions, :mode)
      change_column :chat_sessions, :mode, :string, null: true, default: nil
    else
      add_column :chat_sessions, :mode, :string
    end
  end

  def down
    remove_column :chat_sessions, :mode if column_exists?(:chat_sessions, :mode)
  end
end
