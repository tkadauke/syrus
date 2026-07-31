class AddMaxConcurrentLandingGraderRunsToAppSettings < ActiveRecord::Migration[8.1]
  def up
    unless column_exists?(:app_settings, :max_concurrent_landing_grader_runs)
      add_column :app_settings, :max_concurrent_landing_grader_runs, :integer, default: 2, null: false
    end
  end

  def down
    if column_exists?(:app_settings, :max_concurrent_landing_grader_runs)
      remove_column :app_settings, :max_concurrent_landing_grader_runs
    end
  end
end
