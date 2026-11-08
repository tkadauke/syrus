# Ownership correction: the coworker_review_contexts table was originally
# created by a core migration (20261106105035), which stays untouched because
# it has already landed. This plugin migration makes the plugin able to create
# the table itself (fresh installs where the plugin's migrations run without
# the core one are unaffected on existing databases: every step is a no-op when
# the table or index already exists). The table has no foreign key from core
# tables, so core never depends on it.
class AdoptCoworkerReviewContextsTable < ActiveRecord::Migration[8.1]
  def change
    create_table :coworker_review_contexts, if_not_exists: true do |t|
      t.integer :run_id, null: false
      t.integer :review_evidence_id, null: false
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

    unless index_exists?(:coworker_review_contexts, :run_id, unique: true)
      add_index :coworker_review_contexts, :run_id, unique: true
    end
    unless index_exists?(:coworker_review_contexts, :review_evidence_id, unique: true)
      add_index :coworker_review_contexts, :review_evidence_id, unique: true
    end
  end
end
