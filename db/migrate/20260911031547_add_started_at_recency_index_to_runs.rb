class AddStartedAtRecencyIndexToRuns < ActiveRecord::Migration[8.1]
  def change
    unless index_exists?(:runs, [ :state, :started_at, :id ], name: "idx_runs_state_started_id")
      add_index :runs,
                [ :state, :started_at, :id ],
                name: "idx_runs_state_started_id"
    end
  end
end
