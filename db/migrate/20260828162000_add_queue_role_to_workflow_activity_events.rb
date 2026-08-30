class AddQueueRoleToWorkflowActivityEvents < ActiveRecord::Migration[8.1]
  def change
    add_column :workflow_activity_events, :queue_role, :string unless column_exists?(:workflow_activity_events, :queue_role)
  end
end
