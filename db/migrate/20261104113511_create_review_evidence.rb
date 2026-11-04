class CreateReviewEvidence < ActiveRecord::Migration[8.1]
  def change
    create_table :review_evidences, if_not_exists: true do |t|
      t.references :run, null: false, foreign_key: true, index: { unique: true }
      t.references :workflow, null: false, foreign_key: true
      t.references :step, null: false, foreign_key: true
      t.string :review_kind, null: false
      t.string :provider, null: false
      t.string :model, null: false
      t.string :reviewer_type
      t.bigint :reviewer_id
      t.string :reviewed_base_sha, null: false
      t.string :reviewed_head_sha, null: false
      t.string :canonical_diff_sha256, null: false
      t.string :prompt_version, null: false
      t.string :checklist_version, null: false
      t.string :tool_policy_version, null: false
      t.string :state, null: false, default: "pending"
      t.datetime :submitted_at
      t.datetime :stale_at
      t.datetime :failed_at
      t.string :terminal_failure_code
      t.json :terminal_failure_details
      t.timestamps
    end

    add_index :review_evidences, %i[reviewer_type reviewer_id], if_not_exists: true
    add_index :review_evidences, %i[workflow_id review_kind state], if_not_exists: true
  end
end
