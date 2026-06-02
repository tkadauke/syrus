class AddOwnerToEpics < ActiveRecord::Migration[8.1]
  def up
    add_column :epics, :owner_id, :integer unless column_exists?(:epics, :owner_id)
    add_index :epics, :owner_id unless index_exists?(:epics, :owner_id)
    add_foreign_key :epics, :users, column: :owner_id unless foreign_key_exists?(:epics, :users, column: :owner_id)
    add_column :epics, :claimed_at, :datetime unless column_exists?(:epics, :claimed_at)
    add_index :epics, :claimed_at unless index_exists?(:epics, :claimed_at)
  end

  def down
    remove_index :epics, :claimed_at if index_exists?(:epics, :claimed_at)
    remove_column :epics, :claimed_at if column_exists?(:epics, :claimed_at)
    remove_foreign_key :epics, column: :owner_id if foreign_key_exists?(:epics, :users, column: :owner_id)
    remove_index :epics, :owner_id if index_exists?(:epics, :owner_id)
    remove_column :epics, :owner_id if column_exists?(:epics, :owner_id)
  end
end
