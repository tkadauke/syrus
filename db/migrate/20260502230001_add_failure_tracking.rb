class AddFailureTracking < ActiveRecord::Migration[8.1]
  def change
    add_column :jobs, :failure_count, :integer, default: 0, null: false
    add_column :app_settings, :max_job_failures, :integer, default: 3, null: false
  end
end
