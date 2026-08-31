class AddStepFinishedThroughputIndexToRuns < ActiveRecord::Migration[8.1]
  def change
    add_index :runs,
      [ :step_id, :state, :finished_at, :id ],
      name: "idx_runs_step_state_finished_for_throughput",
      if_not_exists: true
  end
end
