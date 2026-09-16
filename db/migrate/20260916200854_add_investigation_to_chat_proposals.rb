class AddInvestigationToChatProposals < ActiveRecord::Migration[8.1]
  def up
    add_column :chat_proposals, :investigation, :boolean, null: false, default: false unless column_exists?(:chat_proposals, :investigation)
  end

  def down
    remove_column :chat_proposals, :investigation if column_exists?(:chat_proposals, :investigation)
  end
end
