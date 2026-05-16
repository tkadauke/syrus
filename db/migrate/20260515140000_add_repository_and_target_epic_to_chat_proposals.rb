class AddRepositoryAndTargetEpicToChatProposals < ActiveRecord::Migration[8.1]
  def change
    add_reference :chat_proposals, :repository, foreign_key: true unless column_exists?(:chat_proposals, :repository_id)
    add_reference :chat_proposals, :target_epic, foreign_key: { to_table: :epics } unless column_exists?(:chat_proposals, :target_epic_id)
  end
end
