class AddRunFinishedSpendBudgetIndexToRuns < ActiveRecord::Migration[8.1]
  def change
    unless index_exists?(:runs, [ :user_id, :finished_at, :cost_usd ], name: "idx_runs_spending_user_finished_window")
      add_index :runs, [ :user_id, :finished_at, :cost_usd ],
                name: "idx_runs_spending_user_finished_window"
    end
  end
end
