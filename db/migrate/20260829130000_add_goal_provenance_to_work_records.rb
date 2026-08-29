class AddGoalProvenanceToWorkRecords < ActiveRecord::Migration[8.1]
  def change
    add_reference :chat_proposals, :chat_goal, foreign_key: true
    add_column :chat_proposals, :goal_prompt_snapshot, :json

    add_reference :jobs, :chat_goal, foreign_key: true
    add_column :jobs, :goal_prompt_snapshot, :json

    add_reference :epics, :chat_goal, foreign_key: true
    add_column :epics, :goal_prompt_snapshot, :json
  end
end
