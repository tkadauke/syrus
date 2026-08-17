class CreateBrowserErrorSearchTables < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      CREATE VIRTUAL TABLE IF NOT EXISTS browser_error_fts
      USING fts5(
        message,
        search_text,
        browser_error_event_id UNINDEXED,
        occurred_at UNINDEXED,
        app_revision UNINDEXED,
        fingerprint UNINDEXED,
        name UNINDEXED,
        path UNINDEXED,
        user_id UNINDEXED,
        tokenize = 'porter unicode61'
      )
    SQL
  end

  def down
    execute "DROP TABLE IF EXISTS browser_error_fts"
  end
end
