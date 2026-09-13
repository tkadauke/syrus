class DropWorkflowStepWorkerSlots < ActiveRecord::Migration[8.1]
  def change
    drop_table :workflow_step_worker_slots, if_exists: true
  end
end
