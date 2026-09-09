class CreateWorkflowSourceSnapshots < ActiveRecord::Migration[8.1]
  def change
    create_table :workflow_source_snapshots do |t|
      t.references :workflow, null: false, index: true
      t.references :creator_step, null: false, index: true
      t.string :source_sha, null: false
      t.string :source_ref, null: false
      t.string :tree_sha
      t.string :source_fingerprint
      t.datetime :published_at, null: false

      t.timestamps
    end

    add_index :workflow_source_snapshots, [ :workflow_id, :published_at, :id ],
      name: "idx_workflow_source_snapshots_current"
    add_index :workflow_source_snapshots, [ :workflow_id, :source_sha ],
      unique: true,
      name: "idx_workflow_source_snapshots_workflow_sha"
  end
end
