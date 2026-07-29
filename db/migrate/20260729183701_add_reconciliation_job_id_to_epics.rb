class AddReconciliationJobIdToEpics < ActiveRecord::Migration[8.1]
  def up
    add_column :epics, :reconciliation_job_id, :integer unless column_exists?(:epics, :reconciliation_job_id)
    add_index :epics, :reconciliation_job_id unless index_exists?(:epics, :reconciliation_job_id)
  end

  def down
    remove_index :epics, :reconciliation_job_id if index_exists?(:epics, :reconciliation_job_id)
    remove_column :epics, :reconciliation_job_id if column_exists?(:epics, :reconciliation_job_id)
  end
end
