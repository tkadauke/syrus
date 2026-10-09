class CreateJobClassificationAttempts < ActiveRecord::Migration[8.1]
  def up
    return if table_exists?(:job_classification_attempts)

    create_table :job_classification_attempts do |t|
      t.references :job, null: false
      t.datetime :started_at, null: false
      t.datetime :finished_at
      t.string :outcome, limit: 32
      t.json :decision
      t.text :error
      t.text :raw_output, limit: 16.megabytes
      t.string :agent_provider, limit: 64
      t.references :spawned_process, null: true

      t.timestamps

      t.index [ :job_id, :started_at, :id ], name: "idx_job_classification_attempts_job_started"
      t.index [ :job_id, :finished_at ], name: "idx_job_classification_attempts_job_finished"
    end
  end

  def down
    drop_table :job_classification_attempts if table_exists?(:job_classification_attempts)
  end
end
