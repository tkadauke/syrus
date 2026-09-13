class RemoveWorkflowStepWorkerSlotAdmissionSetting < ActiveRecord::Migration[8.1]
  def change
    remove_column :app_settings, :workflow_step_worker_slot_admission_enabled, :boolean, if_exists: true
  end
end
