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

      t.timestamps
    end

    add_index :runtime_control_leases, [ :runtime_session_id, :state ] unless index_exists?(:runtime_control_leases, [ :runtime_session_id, :state ])
    add_index :runtime_control_leases, [ :runtime_session_id, :mode, :state ], name: "index_runtime_control_leases_on_session_mode_state" unless index_exists?(:runtime_control_leases, [ :runtime_session_id, :mode, :state ], name: "index_runtime_control_leases_on_session_mode_state")
  end

  def down
    drop_table :runtime_control_leases, if_exists: true
  end
end
