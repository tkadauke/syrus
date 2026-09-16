class AddInvestigationToChatProposals < ActiveRecord::Migration[8.1]
  def change
    add_column :chat_proposals, :investigation, :boolean, default: false, null: false unless column_exists?(:chat_proposals, :investigation)
  end
end
