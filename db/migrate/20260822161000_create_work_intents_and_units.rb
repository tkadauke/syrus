class CreateWorkIntentsAndUnits < ActiveRecord::Migration[8.1]
  def change
    create_table :work_intents, if_not_exists: true do |t|
      t.string :kind, null: false, limit: 64
      t.string :state, null: false, limit: 32
      t.bigint :repository_id
      t.string :scope_type, null: false, limit: 64
      t.bigint :scope_id
      t.string :delivery_track, limit: 128
      t.bigint :source_repository_id
      t.string :source_remote_kind, limit: 64
      t.string :source_ref, limit: 255
      t.bigint :target_repository_id
      t.string :target_remote_kind, limit: 64
      t.string :target_ref, limit: 255
      t.string :priority, limit: 32
      t.bigint :actor_id
      t.string :source_type, limit: 64
      t.bigint :source_id
      t.string :idempotency_key, limit: 255
      t.string :wait_reason, limit: 64
      t.datetime :wait_until
      t.json :wait_details
      t.bigint :superseded_by_work_intent_id
      t.datetime :requested_at, null: false
      t.datetime :satisfied_at
      t.datetime :cancelled_at

      t.timestamps
    end

    add_index :work_intents, [ :kind, :state, :repository_id ], name: "idx_work_intents_kind_state_repo", if_not_exists: true
    add_index :work_intents, [ :scope_type, :scope_id, :state ], name: "idx_work_intents_scope_state", if_not_exists: true
    add_index :work_intents, :idempotency_key, unique: true, name: "idx_work_intents_idempotency", if_not_exists: true
    add_index :work_intents, :superseded_by_work_intent_id, name: "idx_work_intents_superseded_by", if_not_exists: true

    create_table :work_units, if_not_exists: true do |t|
      t.bigint :work_intent_id, null: false
      t.string :kind, null: false, limit: 64
      t.string :state, null: false, limit: 32
      t.bigint :repository_id
      t.string :scope_type, null: false, limit: 64
      t.bigint :scope_id
      t.string :delivery_track, limit: 128
      t.bigint :parent_work_unit_id
      t.bigint :source_repository_id
      t.string :source_remote_kind, limit: 64
      t.string :source_ref, limit: 255
      t.bigint :target_repository_id
      t.string :target_remote_kind, limit: 64
      t.string :target_ref, limit: 255
      t.bigint :workflow_id
      t.string :blocked_reason, limit: 64
      t.datetime :blocked_until
      t.bigint :blocked_by_user_id
      t.json :blocked_details
      t.boolean :pause_requested, null: false, default: false
      t.bigint :preempted_by_work_unit_id
      t.string :preemption_reason, limit: 64
      t.datetime :started_at
      t.datetime :finished_at

      t.timestamps
    end

    add_index :work_units, [ :work_intent_id, :state ], name: "idx_work_units_intent_state", if_not_exists: true
    add_index :work_units, [ :kind, :state, :repository_id ], name: "idx_work_units_kind_state_repo", if_not_exists: true
    add_index :work_units, [ :scope_type, :scope_id, :state ], name: "idx_work_units_scope_state", if_not_exists: true
    add_index :work_units, :parent_work_unit_id, name: "idx_work_units_parent", if_not_exists: true
    add_index :work_units, :workflow_id, name: "idx_work_units_workflow", if_not_exists: true
    add_index :work_units, [ :blocked_reason, :blocked_until ], name: "idx_work_units_blocked_wakeup", if_not_exists: true
    add_index :work_units, :preempted_by_work_unit_id, name: "idx_work_units_preempted_by", if_not_exists: true

    create_table :work_unit_members, if_not_exists: true do |t|
      t.bigint :work_unit_id, null: false
      t.bigint :job_id, null: false
      t.string :role, null: false, limit: 64

      t.timestamps
    end

    add_index :work_unit_members, [ :work_unit_id, :job_id, :role ], unique: true, name: "idx_work_unit_members_unique", if_not_exists: true
    add_index :work_unit_members, [ :job_id, :role ], name: "idx_work_unit_members_job_role", if_not_exists: true

    create_table :work_unit_locks, if_not_exists: true do |t|
      t.bigint :work_unit_id, null: false
      t.string :lock_key, null: false, limit: 255
      t.datetime :acquired_at, null: false

      t.timestamps
    end

    add_index :work_unit_locks, :lock_key, unique: true, name: "idx_work_unit_locks_lock_key", if_not_exists: true
    add_index :work_unit_locks, :work_unit_id, name: "idx_work_unit_locks_unit", if_not_exists: true
  end
end
