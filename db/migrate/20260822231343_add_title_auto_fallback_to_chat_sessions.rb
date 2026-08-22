class AddTitleAutoFallbackToChatSessions < ActiveRecord::Migration[8.1]
  def change
    unless column_exists?(:chat_sessions, :title_auto_fallback)
      add_column :chat_sessions, :title_auto_fallback, :boolean, default: false, null: false
    end
  end
end
