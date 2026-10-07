class AddWorkflowPreviewHealthCheckTimeoutToAppSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :app_settings, :workflow_preview_health_check_timeout_seconds, :integer, default: 60, null: false unless column_exists?(:app_settings, :workflow_preview_health_check_timeout_seconds)
  end
end
