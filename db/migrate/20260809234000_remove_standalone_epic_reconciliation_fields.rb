class RemoveStandaloneEpicReconciliationFields < ActiveRecord::Migration[8.1]
  def up
    if column_exists?(:epics, :reconciliation_job_id)
      remove_foreign_key :epics, to_table: :jobs if foreign_key_exists?(:epics, :jobs, column: :reconciliation_job_id)
      remove_index :epics, :reconciliation_job_id if index_exists?(:epics, :reconciliation_job_id)
      remove_column :epics, :reconciliation_job_id
    end
    remove_column :epics, :reconciliation_mode if column_exists?(:epics, :reconciliation_mode)
  end

  def down
    add_column :epics, :reconciliation_mode, :string unless column_exists?(:epics, :reconciliation_mode)
    add_reference :epics, :reconciliation_job, foreign_key: { to_table: :jobs } unless column_exists?(:epics, :reconciliation_job_id)
  end
end
