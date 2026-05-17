class AddDashboardPreferencesToUsers < ActiveRecord::Migration[8.1]
  def up
    add_column :users, :dashboard_preferences, :json unless column_exists?(:users, :dashboard_preferences)
  end

  def down
    remove_column :users, :dashboard_preferences if column_exists?(:users, :dashboard_preferences)
  end
end
