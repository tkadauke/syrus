class AddUiEngagementTelemetryEnabledToAppSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :app_settings, :ui_engagement_telemetry_enabled, :boolean, null: false, default: false
  end
end
