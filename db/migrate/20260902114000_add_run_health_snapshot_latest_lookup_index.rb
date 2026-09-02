class AddRunHealthSnapshotLatestLookupIndex < ActiveRecord::Migration[8.1]
  def change
    add_index :run_health_snapshots, [ :run_id, :id ],
      name: "idx_run_health_snapshots_run_latest",
      if_not_exists: true
  end
end
