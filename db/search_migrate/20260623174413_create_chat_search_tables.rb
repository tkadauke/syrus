class CreateChatSearchTables < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      CREATE VIRTUAL TABLE IF NOT EXISTS chat_message_fts
      USING fts5(
        content,
        user_id UNINDEXED,
        chat_session_id UNINDEXED,
        chat_message_id UNINDEXED,
        role UNINDEXED,
        created_at UNINDEXED,
        tokenize = 'porter unicode61'
      )
    SQL

    execute <<~SQL
      CREATE TABLE IF NOT EXISTS chat_search_metadata (
        key TEXT PRIMARY KEY,
        value TEXT
      )
    SQL
  end

  def down
    execute "DROP TABLE IF EXISTS chat_search_metadata"
    execute "DROP TABLE IF EXISTS chat_message_fts"
  end
end
