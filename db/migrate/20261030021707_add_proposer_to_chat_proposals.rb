class AddProposerToChatProposals < ActiveRecord::Migration[8.1]
  def change
    add_reference :chat_proposals, :proposer, polymorphic: true unless column_exists?(:chat_proposals, :proposer_id)
  end
end
