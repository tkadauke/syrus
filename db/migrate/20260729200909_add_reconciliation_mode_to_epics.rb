class AddReconciliationModeToEpics < ActiveRecord::Migration[8.1]
  def up
    add_column :epics, :reconciliation_mode, :string unless column_exists?(:epics, :reconciliation_mode)
  end

  def down
    remove_column :epics, :reconciliation_mode if column_exists?(:epics, :reconciliation_mode)
  end
end
