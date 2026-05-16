class AddGroupedEpicProposalFieldsToChatProposals < ActiveRecord::Migration[8.1]
  def change
    add_reference :chat_proposals, :parent_proposal, foreign_key: { to_table: :chat_proposals }
    add_reference :chat_proposals, :repository, foreign_key: true
    add_column :chat_proposals, :child_position, :integer
  end
end
