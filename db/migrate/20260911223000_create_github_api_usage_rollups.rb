class CreateGithubApiUsageRollups < ActiveRecord::Migration[8.1]
  INDEX_NAME = "idx_github_api_usage_rollups_unique_bucket"

  def up
    unless table_exists?(:github_api_usage_rollups)
      create_table :github_api_usage_rollups do |t|
        t.datetime :bucket_started_at, null: false
        t.string :auth_source, null: false
        t.string :credential_key, null: false
        t.references :installation, foreign_key: true
        t.references :user, foreign_key: true
        t.references :repository, foreign_key: true
        t.string :repository_key, null: false
        t.string :repo_slug
        t.string :operation, null: false
        t.string :resource
        t.integer :request_count, null: false, default: 0
        t.integer :rate_limited_count, null: false, default: 0
        t.integer :last_status
        t.integer :last_remaining
        t.integer :last_limit
        t.datetime :last_reset_at
        t.datetime :last_seen_at, null: false

        t.timestamps
      end
    end

    add_index :github_api_usage_rollups,
      [ :bucket_started_at, :auth_source, :credential_key, :repository_key, :operation, :resource ],
      unique: true,
      name: INDEX_NAME,
      if_not_exists: true
    add_foreign_key :github_api_usage_rollups, :installations, if_not_exists: true
    add_foreign_key :github_api_usage_rollups, :repositories, if_not_exists: true
    add_foreign_key :github_api_usage_rollups, :users, if_not_exists: true
  end

  def down
    drop_table :github_api_usage_rollups, if_exists: true
  end
end
