class CreateGithubApiUsageRollups < ActiveRecord::Migration[8.1]
  def change
    create_table :github_api_usage_rollups do |t|
      t.datetime :bucket_started_at, null: false
      t.string :auth_source, null: false
      t.string :credential_key, null: false
      t.references :installation
      t.references :user
      t.references :repository
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

    add_index :github_api_usage_rollups,
      [ :bucket_started_at, :auth_source, :credential_key, :repository_key, :operation, :resource ],
      unique: true,
      name: "idx_github_api_usage_rollups_unique_bucket"
  end
end
