class AddGoalProvenanceToChatWork < ActiveRecord::Migration[8.1]
  def change
    add_column :chat_proposals, :chat_goal_id, :integer unless column_exists?(:chat_proposals, :chat_goal_id)
    add_column :chat_proposals, :goal_prompt_snapshot, :json unless column_exists?(:chat_proposals, :goal_prompt_snapshot)
    add_index :chat_proposals, :chat_goal_id unless index_exists?(:chat_proposals, :chat_goal_id)
    add_index :chat_proposals, [ :chat_goal_id, :created_at ], name: "index_chat_proposals_on_chat_goal_id_and_created_at" unless index_exists?(:chat_proposals, [ :chat_goal_id, :created_at ], name: "index_chat_proposals_on_chat_goal_id_and_created_at")

    add_column :jobs, :chat_goal_id, :integer unless column_exists?(:jobs, :chat_goal_id)
    add_column :jobs, :goal_prompt_snapshot, :json unless column_exists?(:jobs, :goal_prompt_snapshot)
    add_index :jobs, :chat_goal_id unless index_exists?(:jobs, :chat_goal_id)
    add_index :jobs, [ :chat_goal_id, :created_at ], name: "index_jobs_on_chat_goal_id_and_created_at" unless index_exists?(:jobs, [ :chat_goal_id, :created_at ], name: "index_jobs_on_chat_goal_id_and_created_at")

    add_column :epics, :chat_goal_id, :integer unless column_exists?(:epics, :chat_goal_id)
    add_column :epics, :goal_prompt_snapshot, :json unless column_exists?(:epics, :goal_prompt_snapshot)
    add_index :epics, :chat_goal_id unless index_exists?(:epics, :chat_goal_id)
    add_index :epics, [ :chat_goal_id, :created_at ], name: "index_epics_on_chat_goal_id_and_created_at" unless index_exists?(:epics, [ :chat_goal_id, :created_at ], name: "index_epics_on_chat_goal_id_and_created_at")
  end
end
