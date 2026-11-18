class AddJobFailureHealthToPluginRecords < ActiveRecord::Migration[8.1]
  def change
    add_column :plugin_records, :plugin_job_failure_count, :integer, default: 0, null: false unless column_exists?(:plugin_records, :plugin_job_failure_count)
    add_column :plugin_records, :plugin_job_last_failed_at, :datetime unless column_exists?(:plugin_records, :plugin_job_last_failed_at)
    add_column :plugin_records, :plugin_job_last_error, :string, limit: 500 unless column_exists?(:plugin_records, :plugin_job_last_error)
  end
end
