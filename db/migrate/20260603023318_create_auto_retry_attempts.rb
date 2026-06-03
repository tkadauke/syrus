class CreateAutoRetryAttempts < ActiveRecord::Migration[8.1]
  def up
    create_table :auto_retry_attempts, if_not_exists: true do |t|
      t.references :job, null: false, foreign_key: true
      t.references :workflow, null: false, foreign_key: true
      t.references :run, null: true, foreign_key: true
      t.string :agent_provider, null: false
      t.string :failure_classification, null: false
      t.string :retry_kind, null: false
      t.integer :attempt_number, null: false
      t.datetime :scheduled_at, null: false
      t.datetime :performed_at
      t.string :skipped_reason
      t.timestamps
    end

    unless index_exists?(:auto_retry_attempts, [ :job_id, :agent_provider, :failure_classification ], name: "index_auto_retry_attempts_on_budget")
      add_index :auto_retry_attempts,
                [ :job_id, :agent_provider, :failure_classification ],
                name: "index_auto_retry_attempts_on_budget"
    end

    unless index_exists?(:auto_retry_attempts, [ :workflow_id, :retry_kind ], name: "index_auto_retry_attempts_on_workflow_retry_kind")
      add_index :auto_retry_attempts,
                [ :workflow_id, :retry_kind ],
                name: "index_auto_retry_attempts_on_workflow_retry_kind"
    end
  end

  def down
    drop_table :auto_retry_attempts, if_exists: true
  end
end
