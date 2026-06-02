class AddOwnerUserToDashboardRecords < ActiveRecord::Migration[8.1]
  def up
    add_reference :jobs, :owner_user, null: true, foreign_key: { to_table: :users } unless column_exists?(:jobs, :owner_user_id)
    add_reference :epics, :owner_user, null: true, foreign_key: { to_table: :users } unless column_exists?(:epics, :owner_user_id)
  end

  def down
    remove_reference :jobs, :owner_user, foreign_key: { to_table: :users } if column_exists?(:jobs, :owner_user_id)
    remove_reference :epics, :owner_user, foreign_key: { to_table: :users } if column_exists?(:epics, :owner_user_id)
  end
end
