class MakeWorkUnitLocksReleasable < ActiveRecord::Migration[8.1]
  def change
    add_column :work_unit_locks, :released_at, :datetime unless column_exists?(:work_unit_locks, :released_at)

    if index_exists?(:work_unit_locks, :lock_key, name: "idx_work_unit_locks_lock_key", unique: true)
      remove_index :work_unit_locks, name: "idx_work_unit_locks_lock_key"
    end
    add_index :work_unit_locks, :lock_key, name: "idx_work_unit_locks_lock_key", if_not_exists: true
    add_index :work_unit_locks, [ :lock_key, :released_at ], name: "idx_work_unit_locks_key_release", if_not_exists: true
  end
end
