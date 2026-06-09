class AddCreatedAtCostIndexToRuns < ActiveRecord::Migration[8.1]
  def up
    add_index :runs,
              [ :created_at, :cost_usd ],
              name: "index_runs_on_created_at_and_cost_usd",
              if_not_exists: true
  end

  def down
    remove_index :runs,
                 name: "index_runs_on_created_at_and_cost_usd",
                 if_exists: true
  end
end
