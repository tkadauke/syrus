class AddStartedAtRecencyIndexesToRuns < ActiveRecord::Migration[8.1]
  def change
    add_index :runs,
              [ :state, :started_at, :id ],
              name: "idx_runs_state_started_id",
              if_not_exists: true
  end
end
