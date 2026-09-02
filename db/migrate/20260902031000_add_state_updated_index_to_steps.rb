class AddStateUpdatedIndexToSteps < ActiveRecord::Migration[8.1]
  def change
    add_index :steps,
              [ :state, :updated_at, :id ],
              name: "idx_steps_state_updated_id",
              if_not_exists: true
  end
end
