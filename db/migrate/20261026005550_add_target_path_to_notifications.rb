class AddTargetPathToNotifications < ActiveRecord::Migration[8.1]
  def change
    add_column :notifications, :target_path, :string unless column_exists?(:notifications, :target_path)
  end
end
