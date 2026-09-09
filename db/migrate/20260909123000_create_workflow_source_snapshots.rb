class CreateWorkflowSourceSnapshots < ActiveRecord::Migration[8.1]
  def up
    unless table_exists?(:workflow_source_snapshots)
      create_table :workflow_source_snapshots do |t|
        t.bigint :workflow_id, null: false
        t.string :source_sha, null: false
        t.string :source_ref, null: false
        t.string :tree_sha
        t.string :fingerprint
        t.bigint :creator_step_id, null: false
        t.datetime :published_at, null: false
        t.timestamps
      end
    end

    unless index_exists?(:workflow_source_snapshots, [ :workflow_id, :published_at ], name: "idx_workflow_source_snapshots_current")
      add_index :workflow_source_snapshots, [ :workflow_id, :published_at ], name: "idx_workflow_source_snapshots_current"
    end

    unless index_exists?(:workflow_source_snapshots, :creator_step_id)
      add_index :workflow_source_snapshots, :creator_step_id
    end
  end

  def down
    drop_table :workflow_source_snapshots if table_exists?(:workflow_source_snapshots)
  end
end
