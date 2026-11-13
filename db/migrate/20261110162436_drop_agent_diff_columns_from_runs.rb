class DropAgentDiffColumnsFromRuns < ActiveRecord::Migration[8.1]
  def up
    # Copy anything the previous revision wrote after the backfill ran, so the
    # drop never loses a diff. No-op when the columns are already gone.
    RunDiffs::Backfill.new.call
    remove_column :runs, :agent_diff if column_exists?(:runs, :agent_diff)
    remove_column :runs, :step_agent_diff if column_exists?(:runs, :step_agent_diff)
  end

  def down
    add_column :runs, :agent_diff, :text, limit: 16_777_215 unless column_exists?(:runs, :agent_diff)
    add_column :runs, :step_agent_diff, :text, limit: 16_777_215 unless column_exists?(:runs, :step_agent_diff)
    return unless table_exists?(:run_diffs)

    execute <<~SQL.squish
      UPDATE runs
      SET agent_diff = (SELECT run_diffs.agent_diff FROM run_diffs WHERE run_diffs.run_id = runs.id),
          step_agent_diff = (SELECT run_diffs.step_agent_diff FROM run_diffs WHERE run_diffs.run_id = runs.id)
      WHERE EXISTS (SELECT 1 FROM run_diffs WHERE run_diffs.run_id = runs.id)
    SQL
  end
end
