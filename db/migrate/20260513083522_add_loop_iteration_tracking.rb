class AddLoopIterationTracking < ActiveRecord::Migration[8.1]
  def change
    add_column :steps, :iteration, :integer, null: false, default: 1
    add_column :steps, :loop_id, :string
    add_column :runs, :iteration, :integer, null: false, default: 1

    add_index :steps, [ :workflow_id, :loop_id, :iteration ]
  end
end
