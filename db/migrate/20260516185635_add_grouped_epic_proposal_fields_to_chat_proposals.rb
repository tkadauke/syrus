class AddGroupedEpicProposalFieldsToChatProposals < ActiveRecord::Migration[8.1]
  # `repository_id` is already added by
  # 20260515140000_add_repository_and_target_epic_to_chat_proposals,
  # so it's omitted here. Remaining adds are guarded for idempotency
  # per docs/agent-guide/conventions.md.
  def change
    add_reference :chat_proposals, :parent_proposal, foreign_key: { to_table: :chat_proposals } unless column_exists?(:chat_proposals, :parent_proposal_id)
    add_column :chat_proposals, :child_position, :integer unless column_exists?(:chat_proposals, :child_position)
  end
end
