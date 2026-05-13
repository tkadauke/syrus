class AddNudgeSentToRuns < ActiveRecord::Migration[8.1]
  def change
    unless column_exists?(:runs, :nudge_sent)
      add_column :runs, :nudge_sent, :boolean, default: false, null: false
    end

    unless index_exists?(:runs, [ :state, :nudge_sent, :created_at ], name: "index_runs_on_operator_nudge_window")
      add_index :runs, [ :state, :nudge_sent, :created_at ], name: "index_runs_on_operator_nudge_window"
    end
  end
end
