class AddDistributedWorkflowMetadata < ActiveRecord::Migration[8.1]
  def up
    unless column_exists?(:repositories, :distributed_workflow_dag_enabled)
      add_column :repositories, :distributed_workflow_dag_enabled, :boolean, null: false, default: false
    end

    unless column_exists?(:steps, :placement_policy)
      add_column :steps, :placement_policy, :string, null: false, default: "pinned_workflow_workspace"
    end

    add_index :steps, :placement_policy unless index_exists?(:steps, :placement_policy)
  end

  def down
    remove_index :steps, :placement_policy if index_exists?(:steps, :placement_policy)
    remove_column :steps, :placement_policy if column_exists?(:steps, :placement_policy)
    remove_column :repositories, :distributed_workflow_dag_enabled if column_exists?(:repositories, :distributed_workflow_dag_enabled)
  end
end
