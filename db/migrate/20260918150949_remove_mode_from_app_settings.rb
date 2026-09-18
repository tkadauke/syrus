class RemoveModeFromAppSettings < ActiveRecord::Migration[8.1]
  def up
    remove_column :app_settings, :mode if column_exists?(:app_settings, :mode)
    remove_column :app_settings, :mode_configured_at if column_exists?(:app_settings, :mode_configured_at)
  end

  def down
    add_column :app_settings, :mode, :string, default: "advanced" unless column_exists?(:app_settings, :mode)
    add_column :app_settings, :mode_configured_at, :datetime unless column_exists?(:app_settings, :mode_configured_at)
  end
end
