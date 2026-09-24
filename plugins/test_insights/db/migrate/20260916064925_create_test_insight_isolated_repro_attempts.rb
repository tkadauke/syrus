class CreateTestInsightIsolatedReproAttempts < ActiveRecord::Migration[8.1]
  # Backs Adjudicators::IsolatedReproDismissal: a structured,
  # auditable record of an agent-run isolated repro attempt -- the exact
  # command and raw output, keyed by the exact commit SHA that was actually
  # graded -- kept entirely separate from test_insight_cases/test_insight_runs
  # so it never dilutes TestCase.flakiness_score's statistical `scored` pool.
  #
  # No FK/index on (suite_name, name) the way test_insight_identities does:
  # this table's row volume is tiny (one row per deliberate agent repro
  # attempt, not one per test per run), so a plain [repository_id, sha] index
  # is plenty selective for the lookup this backs.
  def up
    unless table_exists?(:test_insight_isolated_repro_attempts)
      create_table :test_insight_isolated_repro_attempts do |t|
        t.bigint :repository_id, null: false
        t.bigint :job_id
        t.bigint :workflow_id
        t.bigint :run_id
        t.string :grader_name, limit: 128, null: false
        t.string :suite_name, limit: 255, null: false
        t.string :name, limit: 255, null: false
        t.string :sha, limit: 64, null: false
        t.boolean :reproduced, null: false
        t.text :command
        t.text :output
        t.integer :exit_status

        t.timestamps
      end
    end

    unless index_exists?(:test_insight_isolated_repro_attempts, [ :repository_id, :sha ])
      add_index :test_insight_isolated_repro_attempts, [ :repository_id, :sha ], name: "idx_isolated_repro_attempts_on_repo_and_sha"
    end
  end

  def down
    drop_table :test_insight_isolated_repro_attempts if table_exists?(:test_insight_isolated_repro_attempts)
  end
end
