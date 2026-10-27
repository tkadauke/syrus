class AddToolMetadataToJobLogs < ActiveRecord::Migration[8.1]
  def change
    add_column :job_logs, :tool_metadata, :json unless column_exists?(:job_logs, :tool_metadata)
  end
end
