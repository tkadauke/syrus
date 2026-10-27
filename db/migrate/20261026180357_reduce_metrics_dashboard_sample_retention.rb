class ReduceMetricsDashboardSampleRetention < ActiveRecord::Migration[8.1]
  class MigrationAppSetting < ActiveRecord::Base
    self.table_name = "app_settings"
  end

  OLD_PRODUCTION_VALUE = 365
  NEW_DEFAULT = 7

  def up
    return unless column_exists?(:app_settings, :metrics_dashboard_sample_retention_days)

    change_column_default :app_settings, :metrics_dashboard_sample_retention_days, from: 30, to: NEW_DEFAULT
    MigrationAppSetting.reset_column_information
    MigrationAppSetting.where(metrics_dashboard_sample_retention_days: OLD_PRODUCTION_VALUE)
      .update_all(metrics_dashboard_sample_retention_days: NEW_DEFAULT)
  end

  def down
    return unless column_exists?(:app_settings, :metrics_dashboard_sample_retention_days)

    change_column_default :app_settings, :metrics_dashboard_sample_retention_days, from: NEW_DEFAULT, to: 30
  end
end
