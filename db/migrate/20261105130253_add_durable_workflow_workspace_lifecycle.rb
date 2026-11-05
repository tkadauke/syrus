class AddDurableWorkflowWorkspaceLifecycle < ActiveRecord::Migration[8.1]
  def change
    add_column :workflows, :workspace_lifecycle_state, :string unless column_exists?(:workflows, :workspace_lifecycle_state)
    add_column :workflows, :last_workspace_hostname, :string unless column_exists?(:workflows, :last_workspace_hostname)
    add_column :workflows, :last_workspace_storage_key, :string unless column_exists?(:workflows, :last_workspace_storage_key)

    unless table_exists?(:workflow_workspace_events)
      create_table :workflow_workspace_events do |t|
        t.references :workflow, null: false
        t.string :event_type, null: false
        t.string :hostname
        t.string :storage_key
        t.string :actor, null: false
        t.string :reason
        t.json :details
        t.timestamps
      end
    end

    unless index_exists?(:workflow_workspace_events, [ :workflow_id, :created_at, :id ],
      name: "idx_workflow_workspace_events_timeline")
      add_index :workflow_workspace_events, [ :workflow_id, :created_at, :id ],
        name: "idx_workflow_workspace_events_timeline"
    end
    add_index :workflows, :last_workspace_storage_key unless index_exists?(:workflows, :last_workspace_storage_key)

    reversible do |direction|
      direction.up do
        execute <<~SQL.squish
          UPDATE workflows
          SET last_workspace_hostname = worker_hostname,
              last_workspace_storage_key = worker_storage_key,
              workspace_lifecycle_state = 'created'
          WHERE worker_hostname IS NOT NULL OR worker_storage_key IS NOT NULL
        SQL
      end
    end
  end
end
