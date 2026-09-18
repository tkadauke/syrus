class AddModelAndEffortLevelToWorkflowsAndRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :workflows, :model, :string unless column_exists?(:workflows, :model)
    add_column :workflows, :effort_level, :string unless column_exists?(:workflows, :effort_level)
    add_column :runs, :model, :string unless column_exists?(:runs, :model)
    add_column :runs, :effort_level, :string unless column_exists?(:runs, :effort_level)
  end
end
