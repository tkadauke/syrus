class AddStateUpdatedIndexToRuns < ActiveRecord::Migration[8.1]
  def change
    add_index :runs, [ :state, :updated_at, :id ],
              name: "idx_runs_state_updated_id",
              if_not_exists: true
  end
end
