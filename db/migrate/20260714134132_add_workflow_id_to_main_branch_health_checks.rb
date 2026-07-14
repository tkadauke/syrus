class AddWorkflowIdToMainBranchHealthChecks < ActiveRecord::Migration[8.1]
  def up
    add_reference :main_branch_health_checks, :workflow, null: true, foreign_key: true unless column_exists?(:main_branch_health_checks, :workflow_id)
  end

  def down
    remove_reference :main_branch_health_checks, :workflow if column_exists?(:main_branch_health_checks, :workflow_id)
  end
end
