class AddDependsOnJobRequirementsToChatProposals < ActiveRecord::Migration[8.1]
  def change
    add_column :chat_proposals, :dependency_requirements, :json unless column_exists?(:chat_proposals, :dependency_requirements)
  end
end
