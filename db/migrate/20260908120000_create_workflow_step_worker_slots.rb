class CreateWorkflowStepWorkerSlots < ActiveRecord::Migration[8.1]
  def change
    unless table_exists?(:workflow_step_worker_slots)
      create_table :workflow_step_worker_slots do |t|
        t.bigint :workflow_id, null: false
        t.bigint :step_id, null: false
        t.bigint :run_id, null: false
        t.string :worker_key, null: false
        t.string :worker_hostname
        t.string :worker_storage_key
        t.string :active_slot_key
        t.datetime :acquired_at, null: false
        t.datetime :released_at
        t.string :release_reason

        t.timestamps
      end
    end

    add_index :workflow_step_worker_slots, :workflow_id unless index_exists?(:workflow_step_worker_slots, :workflow_id)
    add_index :workflow_step_worker_slots, :step_id unless index_exists?(:workflow_step_worker_slots, :step_id)
    add_index :workflow_step_worker_slots, :run_id unless index_exists?(:workflow_step_worker_slots, :run_id)
    unless index_exists?(:workflow_step_worker_slots, [ :worker_key, :released_at ], name: "idx_workflow_step_worker_slots_worker_release")
      add_index :workflow_step_worker_slots, [ :worker_key, :released_at ], name: "idx_workflow_step_worker_slots_worker_release"
    end
    unless index_exists?(:workflow_step_worker_slots, :active_slot_key, name: "idx_workflow_step_worker_slots_active_key")
      add_index :workflow_step_worker_slots, :active_slot_key, unique: true, name: "idx_workflow_step_worker_slots_active_key"
    end

    unless column_exists?(:app_settings, :workflow_step_worker_slot_admission_enabled)
      add_column :app_settings, :workflow_step_worker_slot_admission_enabled, :boolean, default: false, null: false
    end
  end
end
