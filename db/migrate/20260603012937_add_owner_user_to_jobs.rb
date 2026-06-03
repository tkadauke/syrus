class AddOwnerUserToJobs < ActiveRecord::Migration[8.1]
  def up
    add_column :jobs, :owner_user_id, :bigint unless column_exists?(:jobs, :owner_user_id)
    add_index :jobs, :owner_user_id unless index_exists?(:jobs, :owner_user_id)
    add_foreign_key :jobs, :users, column: :owner_user_id unless foreign_key_exists?(:jobs, :users, column: :owner_user_id)
  end

  def down
    remove_foreign_key :jobs, column: :owner_user_id if foreign_key_exists?(:jobs, :users, column: :owner_user_id)
    remove_index :jobs, :owner_user_id if index_exists?(:jobs, :owner_user_id)
    remove_column :jobs, :owner_user_id if column_exists?(:jobs, :owner_user_id)
  end
end
