class CreateCognitiveEngagementEvents < ActiveRecord::Migration[8.1]
  def up
    create_table :cognitive_engagement_events, if_not_exists: true do |t|
      t.references :repository, null: false, foreign_key: false
      t.references :user, null: false, foreign_key: false
      t.references :diff_review_version, null: true, foreign_key: false
      t.string :source_type, null: false, limit: 64
      t.string :engagement_kind, null: false, limit: 32
      t.string :evidence_type, null: false, limit: 64
      t.bigint :evidence_id
      t.string :evidence_key, null: false
      t.datetime :occurred_at, null: false
      t.string :commit_sha
      t.string :base_sha
      t.string :head_sha
      t.string :anchor_kind, null: false, limit: 32
      t.string :anchor_key, null: false
      t.string :idempotency_key, null: false, limit: 64
      t.string :path
      t.string :side, limit: 16
      t.integer :start_line
      t.integer :end_line
      t.decimal :weight, precision: 4, scale: 3, null: false
      t.decimal :confidence, precision: 4, scale: 3
      t.string :quality, limit: 64
      t.json :metadata, null: false
      t.timestamps
    end

    idempotency_index = [ :repository_id, :user_id, :source_type, :idempotency_key ]
    unless index_exists?(:cognitive_engagement_events, idempotency_index, name: "idx_cognitive_engagement_events_idempotency")
      add_index :cognitive_engagement_events,
        idempotency_index,
        unique: true,
        name: "idx_cognitive_engagement_events_idempotency"
    end

    repo_path_time_index = [ :repository_id, :path, :occurred_at, :id ]
    unless index_exists?(:cognitive_engagement_events, repo_path_time_index, name: "idx_cognitive_engagement_events_repo_path_time")
      add_index :cognitive_engagement_events,
        repo_path_time_index,
        name: "idx_cognitive_engagement_events_repo_path_time",
        length: { path: 191 }
    end

    repo_source_time_index = [ :repository_id, :source_type, :occurred_at, :id ]
    unless index_exists?(:cognitive_engagement_events, repo_source_time_index, name: "idx_cognitive_engagement_events_repo_source_time")
      add_index :cognitive_engagement_events,
        repo_source_time_index,
        name: "idx_cognitive_engagement_events_repo_source_time",
        length: { source_type: 32 }
    end

    diff_identity_index = [ :repository_id, :base_sha, :head_sha, :path ]
    unless index_exists?(:cognitive_engagement_events, diff_identity_index, name: "idx_cognitive_engagement_events_diff_identity")
      add_index :cognitive_engagement_events,
        diff_identity_index,
        name: "idx_cognitive_engagement_events_diff_identity",
        length: { base_sha: 64, head_sha: 64, path: 191 }
    end
  end

  def down
    drop_table :cognitive_engagement_events, if_exists: true
  end
end
