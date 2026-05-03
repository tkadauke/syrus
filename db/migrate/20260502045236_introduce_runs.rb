class IntroduceRuns < ActiveRecord::Migration[8.1]
  def up
    create_table :runs do |t|
      t.references :job, null: false, foreign_key: true
      t.string :trigger_kind, null: false
      t.string :state, null: false, default: "queued"
      t.datetime :started_at
      t.datetime :finished_at
      t.integer :agent_turns
      t.string :agent_outcome
      t.text :agent_diff
      t.string :head_sha
      t.text :prompt
      t.timestamps
    end

    add_index :runs, [ :job_id, :state ]

    add_reference :job_logs, :run, foreign_key: true

    # Backfill: one Run per existing Job, copying agent_* + timing.
    execute(<<~SQL)
      INSERT INTO runs (job_id, trigger_kind, state, started_at, finished_at,
                        agent_turns, agent_outcome, agent_diff, created_at, updated_at)
      SELECT id,
             'initial',
             state,
             started_at, finished_at,
             agent_turns, agent_outcome, agent_diff,
             created_at, updated_at
      FROM jobs
    SQL

    # Reassign job_logs to their parent's initial Run.
    execute(<<~SQL)
      UPDATE job_logs
      SET run_id = (
        SELECT id FROM runs
        WHERE runs.job_id = job_logs.job_id
        ORDER BY runs.id ASC
        LIMIT 1
      )
    SQL

    # Drop the now-stale parent — every JobLog must hang off a Run.
    change_column_null :job_logs, :run_id, false

    # Replace the (job_id, sequence) unique index with (run_id, sequence)
    # before removing the job_id column. On SQLite remove_reference rebuilds
    # the table; if the old index still mentions job_id at that point it
    # collapses into a unique-on-sequence-alone constraint that explodes
    # the moment two runs share a sequence number.
    remove_index :job_logs, name: "index_job_logs_on_job_id_and_sequence"
    add_index :job_logs, [ :run_id, :sequence ], unique: true

    remove_reference :job_logs, :job, foreign_key: true

    # Move agent_* state off Job entirely; they live on Run now.
    remove_column :jobs, :agent_diff
    remove_column :jobs, :agent_turns
    remove_column :jobs, :agent_outcome

    # Job becomes the persistent thread. Closure_reason captures *why*
    # the thread ended (pr_merged, pr_closed, syrus_stop, cancelled, manual).
    add_column :jobs, :closure_reason, :string

    # Translate old Job states into the new open/closed pair.
    # Anything that hadn't been cancelled stays "open" — succeeded threads
    # may receive PR feedback; failed threads can be retried.
    execute "UPDATE jobs SET closure_reason = 'cancelled' WHERE state = 'cancelled'"
    execute "UPDATE jobs SET state = 'closed' WHERE state = 'cancelled'"
    execute "UPDATE jobs SET state = 'open' WHERE state IN ('queued', 'running', 'succeeded', 'failed')"

    # Reset finished_at on still-open Jobs — at the thread level they
    # aren't finished even if the initial Run was.
    execute "UPDATE jobs SET finished_at = NULL WHERE state = 'open'"

    change_column_default :jobs, :state, "open"
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
