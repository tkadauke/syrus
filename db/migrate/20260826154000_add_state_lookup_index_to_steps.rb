class AddStateLookupIndexToSteps < ActiveRecord::Migration[8.1]
  def change
    return if index_exists?(:steps, [ :state, :workflow_id, :id ], name: "idx_steps_state_workflow_id")

    add_index :steps, [ :state, :workflow_id, :id ], name: "idx_steps_state_workflow_id"
  end
end
