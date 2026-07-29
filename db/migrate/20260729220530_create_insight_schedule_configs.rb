class CreateInsightScheduleConfigs < ActiveRecord::Migration[8.1]
  def up
    create_table :insight_schedule_configs, if_not_exists: true do |t|
      t.references :repository, null: false, foreign_key: true, index: { unique: true }
      t.boolean  :enabled,                  null: false, default: false
      t.integer  :min_jobs_since_last_run,  null: false, default: 5
      t.integer  :max_jobs_since_last_run,  null: false, default: 10
      t.timestamps
    end
  end

  def down
    drop_table :insight_schedule_configs, if_exists: true
  end
end
