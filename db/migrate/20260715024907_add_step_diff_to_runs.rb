class AddStepDiffToRuns < ActiveRecord::Migration[8.1]
  def up
    add_column :runs, :base_sha, :string unless column_exists?(:runs, :base_sha)
    add_column :runs, :step_agent_diff, :text, limit: 16777215 unless column_exists?(:runs, :step_agent_diff)
  end

  def down
    remove_column :runs, :step_agent_diff if column_exists?(:runs, :step_agent_diff)
    remove_column :runs, :base_sha if column_exists?(:runs, :base_sha)
  end
end
