class CreateGithubApiUsageRollups < ActiveRecord::Migration[8.1]
  INDEX_NAME = "idx_github_api_usage_rollups_unique_bucket"
  STRING_LIMITS = {
    auth_source: 32,
    credential_key: 64,
    repository_key: 96,
    operation: 96,
    resource: 32
  }.freeze

  def up
    unless table_exists?(:github_api_usage_rollups)
      create_table :github_api_usage_rollups do |t|
        t.datetime :bucket_started_at, null: false
        t.string :auth_source, null: false, limit: STRING_LIMITS.fetch(:auth_source)
        t.string :credential_key, null: false, limit: STRING_LIMITS.fetch(:credential_key)
        t.references :installation
        t.references :user
        t.references :repository
        t.string :repository_key, null: false, limit: STRING_LIMITS.fetch(:repository_key)
        t.string :repo_slug
        t.string :operation, null: false, limit: STRING_LIMITS.fetch(:operation)
        t.string :resource, null: false, default: "unknown", limit: STRING_LIMITS.fetch(:resource)
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

    STRING_LIMITS.each do |column, limit|
      if column == :resource
        change_column_default :github_api_usage_rollups, :resource, from: nil, to: "unknown"
        update("UPDATE github_api_usage_rollups SET resource = 'unknown' WHERE resource IS NULL")
      end
      change_column :github_api_usage_rollups, column, :string, limit: limit, null: false if column_exists?(:github_api_usage_rollups, column)
    end

    unless index_exists?(:github_api_usage_rollups, [ :bucket_started_at, :auth_source, :credential_key, :repository_key, :operation, :resource ], name: INDEX_NAME)
      add_index :github_api_usage_rollups,
        [ :bucket_started_at, :auth_source, :credential_key, :repository_key, :operation, :resource ],
        unique: true,
        name: INDEX_NAME,
        length: { auth_source: 32, credential_key: 64, repository_key: 96, operation: 96, resource: 32 }
    end
  end

  def down
    drop_table :github_api_usage_rollups, if_exists: true
  end
end
