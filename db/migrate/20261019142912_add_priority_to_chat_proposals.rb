class AddPriorityToChatProposals < ActiveRecord::Migration[8.1]
  def change
    add_column :chat_proposals, :priority, :string, default: "medium", null: false unless column_exists?(:chat_proposals, :priority)
  end
end
