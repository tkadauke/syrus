class RemoveUserApprovedAtFromEpics < ActiveRecord::Migration[8.1]
  def up
    remove_column :epics, :user_approved_at if column_exists?(:epics, :user_approved_at)
  end

  def down
    add_column :epics, :user_approved_at, :datetime unless column_exists?(:epics, :user_approved_at)
  end
end
