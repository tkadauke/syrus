class AddGoalProvenanceForeignKeys < ActiveRecord::Migration[8.1]
  def change
    add_foreign_key :chat_proposals, :chat_goals unless foreign_key_exists?(:chat_proposals, :chat_goals)
    add_foreign_key :jobs, :chat_goals unless foreign_key_exists?(:jobs, :chat_goals)
    add_foreign_key :epics, :chat_goals unless foreign_key_exists?(:epics, :chat_goals)
  end
end
