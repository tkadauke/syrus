class AddTestInsightCaseRetentionDaysToAppSettings < ActiveRecord::Migration[8.1]
  def up
    return if column_exists?(:app_settings, :test_insight_case_retention_days)

    add_column :app_settings, :test_insight_case_retention_days, :integer, default: 90, null: false
  end

  def down
    remove_column :app_settings, :test_insight_case_retention_days if column_exists?(:app_settings, :test_insight_case_retention_days)
  end
end
