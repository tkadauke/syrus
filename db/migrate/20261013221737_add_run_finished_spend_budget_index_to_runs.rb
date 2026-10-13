class AddRunFinishedSpendBudgetIndexToRuns < ActiveRecord::Migration[8.1]
  def change
    add_index :runs, [ :user_id, :finished_at, :cost_usd ],
              name: "idx_runs_spending_user_finished_window",
              if_not_exists: true
  end
end
