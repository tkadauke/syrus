class CreateDiffReviewVersions < ActiveRecord::Migration[8.1]
  def change
    create_table :diff_review_versions do |t|
      t.integer :job_id, null: false
      t.integer :workflow_id
      t.integer :run_id
      t.integer :version_index, null: false
      t.string :base_sha, null: false
      t.string :head_sha, null: false
      t.string :base_ref
      t.string :head_ref
      t.string :source_key, null: false
      t.string :trigger_kind
      t.string :label
      t.string :reason
      t.boolean :truncated, default: false, null: false
      t.json :files_snapshot, null: false
      t.json :metadata, null: false

      t.timestamps
    end

    add_index :diff_review_versions, [ :job_id, :version_index ], unique: true
    add_index :diff_review_versions, [ :job_id, :base_sha, :head_sha, :source_key ],
              unique: true,
              name: "idx_diff_review_versions_identity"
    add_index :diff_review_versions, [ :job_id, :created_at, :id ]
    add_index :diff_review_versions, :workflow_id
    add_index :diff_review_versions, :run_id
  end
end
