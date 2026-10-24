class AddUiEngagementTelemetryEnabledToAppSettings < ActiveRecord::Migration[8.1]
  def up
    add_column :app_settings, :ui_engagement_telemetry_enabled, :boolean, null: false, default: false unless column_exists?(:app_settings, :ui_engagement_telemetry_enabled)
  end

  def down
    remove_column :app_settings, :ui_engagement_telemetry_enabled if column_exists?(:app_settings, :ui_engagement_telemetry_enabled)
  end
end
