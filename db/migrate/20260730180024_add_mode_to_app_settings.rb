class AddModeToAppSettings < ActiveRecord::Migration[8.1]
  def up
    add_column :app_settings, :mode, :string, default: "advanced" unless column_exists?(:app_settings, :mode)
    add_column :app_settings, :mode_configured_at, :datetime unless column_exists?(:app_settings, :mode_configured_at)
  end

  def down
    remove_column :app_settings, :mode_configured_at if column_exists?(:app_settings, :mode_configured_at)
    remove_column :app_settings, :mode if column_exists?(:app_settings, :mode)
  end
end
