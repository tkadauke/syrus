class AddReconciliationJobToEpics < ActiveRecord::Migration[8.1]
  def up
    unless column_exists?(:epics, :reconciliation_job_id)
      add_reference :epics, :reconciliation_job, null: true, foreign_key: { to_table: :jobs }
    end
  end

  def down
    remove_reference :epics, :reconciliation_job if column_exists?(:epics, :reconciliation_job_id)
  end
end
