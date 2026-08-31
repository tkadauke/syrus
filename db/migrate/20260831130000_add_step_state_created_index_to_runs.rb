class AddStepStateCreatedIndexToRuns < ActiveRecord::Migration[8.1]
  def change
    add_index :runs,
              [ :step_id, :state, :created_at, :id ],
              name: "idx_runs_step_state_created_latest",
              if_not_exists: true
  end
end
