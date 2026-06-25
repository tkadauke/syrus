class AddNotificationPreferencesToUsers < ActiveRecord::Migration[8.1]
  def up
    unless column_exists?(:users, :notification_preferences)
      add_column :users, :notification_preferences, :json
    end

    execute "UPDATE users SET notification_preferences = '{}' WHERE notification_preferences IS NULL" if column_exists?(:users, :notification_preferences)
    change_column_null :users, :notification_preferences, false if column_exists?(:users, :notification_preferences)
  end

  def down
    remove_column :users, :notification_preferences if column_exists?(:users, :notification_preferences)
  end
end
