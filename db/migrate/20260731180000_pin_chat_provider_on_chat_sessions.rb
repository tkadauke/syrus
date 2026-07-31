class PinChatProviderOnChatSessions < ActiveRecord::Migration[8.1]
  def up
    return unless column_exists?(:chat_sessions, :chat_provider)

    say_with_time "Backfilling chat session providers" do
      execute <<~SQL.squish
        UPDATE chat_sessions
        SET chat_provider = COALESCE(
          NULLIF((SELECT users.chat_provider FROM users WHERE users.id = chat_sessions.user_id), ''),
          NULLIF((SELECT users.agent_provider FROM users WHERE users.id = chat_sessions.user_id), ''),
          'claude'
        )
        WHERE chat_provider IS NULL OR chat_provider = ''
      SQL
    end

    change_column_null :chat_sessions, :chat_provider, false
  end

  def down
    return unless column_exists?(:chat_sessions, :chat_provider)

    change_column_null :chat_sessions, :chat_provider, true
  end
end
