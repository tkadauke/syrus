class CreateTestIdentitySearchTables < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      CREATE VIRTUAL TABLE IF NOT EXISTS test_identity_fts
      USING fts5(
        name,
        suite_name,
        file_path,
        test_identity_id UNINDEXED,
        user_id UNINDEXED,
        repository_id UNINDEXED,
        last_status UNINDEXED,
        last_seen_at UNINDEXED,
        tokenize = 'porter unicode61'
      )
    SQL
  end

  def down
    execute "DROP TABLE IF EXISTS test_identity_fts"
  end
end
