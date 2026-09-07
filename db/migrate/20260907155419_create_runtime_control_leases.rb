class CreateRuntimeControlLeases < ActiveRecord::Migration[8.1]
  def up
    create_table :runtime_control_leases, if_not_exists: true do |t|
      t.references :runtime_session, null: false
      t.string :owner, null: false, default: "none"
      t.string :owner_ref
      t.string :mode, null: false
      t.string :state, null: false, default: "active"
      t.text :reason
      t.text :cancel_reason
      t.datetime :acquired_at
      t.datetime :expires_at
      t.datetime :released_at
      t.boolean :cancellable, null: false, default: true
      # Set to "<runtime_session_id>:<serialization_group>" while the lease is
      # active, nil once it ends (mirrors WorkUnitLock#active_lock_key). The
      # unique index below is the actual concurrency guarantee: unlike a
      # `SELECT ... FOR UPDATE` conflict check, which can't lock rows that
      # don't exist yet, a DB-level unique constraint makes two concurrent
      # `acquire!` calls for the same group physically unable to both insert
      # an active row, regardless of transaction isolation level.
      t.string :active_group_key

      t.timestamps
    end

    add_index :runtime_control_leases, [ :runtime_session_id, :state ] unless index_exists?(:runtime_control_leases, [ :runtime_session_id, :state ])
    add_index :runtime_control_leases, [ :runtime_session_id, :mode, :state ], name: "index_runtime_control_leases_on_session_mode_state" unless index_exists?(:runtime_control_leases, [ :runtime_session_id, :mode, :state ], name: "index_runtime_control_leases_on_session_mode_state")
    unless index_exists?(:runtime_control_leases, :active_group_key, name: "idx_runtime_control_leases_active_group_key_unique")
      add_index :runtime_control_leases, :active_group_key, unique: true, name: "idx_runtime_control_leases_active_group_key_unique"
    end
  end

  def down
    drop_table :runtime_control_leases, if_exists: true
  end
end
