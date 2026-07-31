class AddNonlinearDependencyOverrideToChatProposals < ActiveRecord::Migration[8.1]
  def change
    unless column_exists?(:chat_proposals, :nonlinear_dependency_override)
      add_column :chat_proposals, :nonlinear_dependency_override, :boolean, null: false, default: false
    end
  end
end
