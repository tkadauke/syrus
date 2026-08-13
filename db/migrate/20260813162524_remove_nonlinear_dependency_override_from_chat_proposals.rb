class RemoveNonlinearDependencyOverrideFromChatProposals < ActiveRecord::Migration[8.1]
  def up
    remove_column :chat_proposals, :nonlinear_dependency_override if column_exists?(:chat_proposals, :nonlinear_dependency_override)
  end

  def down
    return if column_exists?(:chat_proposals, :nonlinear_dependency_override)

    add_column :chat_proposals, :nonlinear_dependency_override, :boolean, null: false, default: false
  end
end
