class AddKindToJobLogs < ActiveRecord::Migration[8.1]
  def change
    add_column :job_logs, :kind, :string
  end
end
