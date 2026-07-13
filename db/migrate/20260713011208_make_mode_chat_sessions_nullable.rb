class MakeModeChatSessionsNullable < ActiveRecord::Migration[8.1]
  def up
    change_column_null :chat_sessions, :mode, true if column_exists?(:chat_sessions, :mode)
    change_column_default :chat_sessions, :mode, from: "planning", to: nil if column_exists?(:chat_sessions, :mode)
  end

  def down
    change_column_default :chat_sessions, :mode, from: nil, to: "planning" if column_exists?(:chat_sessions, :mode)
    change_column_null :chat_sessions, :mode, false if column_exists?(:chat_sessions, :mode)
  end
end
