class ConvertUserAdminToGlobalRole < ActiveRecord::Migration[8.1]
  def up
    add_column :users, :global_role, :string, default: "user", null: false unless column_exists?(:users, :global_role)

    if column_exists?(:users, :admin)
      execute "UPDATE users SET global_role = 'admin' WHERE admin = TRUE"
      remove_column :users, :admin
    end
  end

  def down
    add_column :users, :admin, :boolean, default: false, null: false unless column_exists?(:users, :admin)

    if column_exists?(:users, :global_role)
      execute "UPDATE users SET admin = TRUE WHERE global_role = 'admin'"
      remove_column :users, :global_role
    end
  end
end
