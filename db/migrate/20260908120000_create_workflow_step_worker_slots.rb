class CreateWorkflowStepWorkerSlots < ActiveRecord::Migration[8.1]
  def change
    create_table :workflow_step_worker_slots, if_not_exists: true do |t|
      t.references :run, null: false, foreign_key: true
      t.references :workflow, null: false, foreign_key: true
      t.references :step, null: false, foreign_key: true
      t.string :worker_hostname, null: false
      t.string :worker_storage_key
      t.string :slot_key, null: false
      t.string :slot_key_source, null: false
      t.string :active_slot_key
      t.datetime :acquired_at, null: false
      t.datetime :released_at
      t.string :release_reason
      t.timestamps
    end

    add_index :workflow_step_worker_slots, :active_slot_key,
              unique: true,
              name: "idx_workflow_step_worker_slots_active_key",
              if_not_exists: true
    add_index :workflow_step_worker_slots, [ :slot_key, :released_at ],
              name: "idx_workflow_step_worker_slots_key_release",
              if_not_exists: true
  end
end
