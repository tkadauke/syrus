class AddMainConcernReportThresholdToAppSettings < ActiveRecord::Migration[8.1]
  def up
    add_column :app_settings, :main_concern_report_threshold, :integer, default: 2, null: false unless column_exists?(:app_settings, :main_concern_report_threshold)
  end

  def down
    remove_column :app_settings, :main_concern_report_threshold if column_exists?(:app_settings, :main_concern_report_threshold)
  end
end
