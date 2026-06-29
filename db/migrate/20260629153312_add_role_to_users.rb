class AddRoleToUsers < ActiveRecord::Migration[8.1]
  def up
    add_column :users, :role, :string, default: "developer", null: false unless column_exists?(:users, :role)
  end

  def down
    remove_column :users, :role if column_exists?(:users, :role)
  end
end
