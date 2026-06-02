class AddOwnerUserToEpics < ActiveRecord::Migration[8.1]
  def up
    add_column :epics, :owner_user_id, :integer unless column_exists?(:epics, :owner_user_id)
    add_index :epics, :owner_user_id unless index_exists?(:epics, :owner_user_id)
    add_foreign_key :epics, :users, column: :owner_user_id unless foreign_key_exists?(:epics, :users, column: :owner_user_id)
  end

  def down
    remove_foreign_key :epics, column: :owner_user_id if foreign_key_exists?(:epics, :users, column: :owner_user_id)
    remove_index :epics, :owner_user_id if index_exists?(:epics, :owner_user_id)
    remove_column :epics, :owner_user_id if column_exists?(:epics, :owner_user_id)
  end
end
