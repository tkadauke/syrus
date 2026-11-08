class AddPermissionsEnforcedToAppSettings < ActiveRecord::Migration[8.1]
  def change
    return if column_exists?(:app_settings, :permissions_enforced)

    add_column :app_settings, :permissions_enforced, :boolean, default: true, null: false
  end
end
