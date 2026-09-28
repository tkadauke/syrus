class CreateCognitiveEngagementEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :cognitive_engagement_events do |t|
      t.references :repository, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
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

    add_index :cognitive_engagement_events,
      [ :repository_id, :user_id, :source_type, :evidence_key, :anchor_key ],
      unique: true,
      name: "idx_cognitive_engagement_events_idempotency",
      length: { source_type: 32, evidence_key: 191, anchor_key: 191 }

    add_index :cognitive_engagement_events,
      [ :repository_id, :path, :occurred_at, :id ],
      name: "idx_cognitive_engagement_events_repo_path_time",
      length: { path: 191 }

    add_index :cognitive_engagement_events,
      [ :repository_id, :source_type, :occurred_at, :id ],
      name: "idx_cognitive_engagement_events_repo_source_time",
      length: { source_type: 32 }

    add_index :cognitive_engagement_events,
      [ :repository_id, :base_sha, :head_sha, :path ],
      name: "idx_cognitive_engagement_events_diff_identity",
      length: { base_sha: 64, head_sha: 64, path: 191 }
  end
end
