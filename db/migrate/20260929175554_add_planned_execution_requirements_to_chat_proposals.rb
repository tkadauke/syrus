class AddPlannedExecutionRequirementsToChatProposals < ActiveRecord::Migration[8.1]
  def change
    add_column :chat_proposals, :planned_execution_project_label, :string unless column_exists?(:chat_proposals, :planned_execution_project_label)
    add_column :chat_proposals, :planned_execution_target_label, :string unless column_exists?(:chat_proposals, :planned_execution_target_label)
    add_column :chat_proposals, :planned_execution_capabilities, :json unless column_exists?(:chat_proposals, :planned_execution_capabilities)
    add_column :chat_proposals, :planned_execution_source, :string unless column_exists?(:chat_proposals, :planned_execution_source)
  end
end
