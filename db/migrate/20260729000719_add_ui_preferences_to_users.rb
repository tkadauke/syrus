class AddUiPreferencesToUsers < ActiveRecord::Migration[8.1]
  def up
    unless column_exists?(:users, :ui_preferences)
      add_column :users, :ui_preferences, :json
    end

    execute "UPDATE users SET ui_preferences = '{}' WHERE ui_preferences IS NULL" if column_exists?(:users, :ui_preferences)
    change_column_null :users, :ui_preferences, false if column_exists?(:users, :ui_preferences)
  end

  def down
    remove_column :users, :ui_preferences if column_exists?(:users, :ui_preferences)
  end
end
