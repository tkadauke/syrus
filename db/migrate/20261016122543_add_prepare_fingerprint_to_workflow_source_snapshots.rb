class AddPrepareFingerprintToWorkflowSourceSnapshots < ActiveRecord::Migration[8.1]
  INDEX_NAME = "idx_wf_source_snapshots_prepare_fingerprint"

  def up
    unless column_exists?(:workflow_source_snapshots, :prepare_fingerprint)
      add_column :workflow_source_snapshots, :prepare_fingerprint, :string
    end
    unless index_exists?(:workflow_source_snapshots, name: INDEX_NAME)
      add_index :workflow_source_snapshots, [ :prepare_fingerprint, :id ], name: INDEX_NAME
    end
  end

  def down
    remove_index :workflow_source_snapshots, name: INDEX_NAME if index_exists?(:workflow_source_snapshots, name: INDEX_NAME)
    remove_column :workflow_source_snapshots, :prepare_fingerprint if column_exists?(:workflow_source_snapshots, :prepare_fingerprint)
  end
end
