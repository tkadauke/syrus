class AddTimeZonePreferencesToUsers < ActiveRecord::Migration[8.1]
  def up
    add_column :users, :time_zone, :string, default: "Etc/UTC", null: false unless column_exists?(:users, :time_zone)
    add_column :users, :time_zone_mode, :string, default: "automatic", null: false unless column_exists?(:users, :time_zone_mode)
  end

  def down
    remove_column :users, :time_zone_mode if column_exists?(:users, :time_zone_mode)
    remove_column :users, :time_zone if column_exists?(:users, :time_zone)
  end
end
