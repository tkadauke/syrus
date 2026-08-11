class AddArtifactsToChatSessions < ActiveRecord::Migration[8.1]
  # Chat-surface counterpart to Workflow#artifacts / Step#details: a
  # kind-specific JSON bag, here for typed artifacts a chat agent submits
  # via the chat submit_artifact MCP tool.
  #
  # MySQL 8 rejects defaults on JSON columns at migration time (SQLite dev
  # accepts them, hides the issue). Follow the nullable->backfill->
  # change_column_null pattern. Model gets an after_initialize seed so new
  # records carry `{}` even without a DB default.
  def up
    unless column_exists?(:chat_sessions, :artifacts)
      add_column :chat_sessions, :artifacts, :json
      execute "UPDATE chat_sessions SET artifacts = '{}' WHERE artifacts IS NULL"
      change_column_null :chat_sessions, :artifacts, false
    end
  end

  def down
    remove_column :chat_sessions, :artifacts if column_exists?(:chat_sessions, :artifacts)
  end
end
