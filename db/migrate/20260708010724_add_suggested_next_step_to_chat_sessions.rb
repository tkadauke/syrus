class AddSuggestedNextStepToChatSessions < ActiveRecord::Migration[8.1]
  def up
    add_column :chat_sessions, :suggested_next_step, :string unless column_exists?(:chat_sessions, :suggested_next_step)
  end

  def down
    remove_column :chat_sessions, :suggested_next_step if column_exists?(:chat_sessions, :suggested_next_step)
  end
end
