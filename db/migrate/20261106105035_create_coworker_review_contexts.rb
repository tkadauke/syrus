class CreateCoworkerReviewContexts < ActiveRecord::Migration[8.1]
  def change
    create_table :coworker_review_contexts do |t|
      t.references :run, null: false, index: { unique: true }, foreign_key: false
      t.references :review_evidence, null: false, index: { unique: true }, foreign_key: false
      t.integer :coworker_id
      t.json :manifest
      t.text :exact_context
      t.string :workspace_path
      t.string :persistence_state, null: false, default: "prepared"
      t.string :persisted_commit_sha
      t.string :persistence_error_code
      t.json :persistence_error_details
      t.datetime :persisted_at
      t.datetime :tombstoned_at

      t.timestamps
    end
  end
end
