class AddDistributedWorkflowMetadata < ActiveRecord::Migration[8.1]
  def change
    add_column :repositories, :distributed_workflow_dag_enabled, :boolean, null: false, default: false
    add_column :steps, :placement_policy, :string, null: false, default: "pinned_workflow_workspace"
    add_index :steps, :placement_policy
  end
end
