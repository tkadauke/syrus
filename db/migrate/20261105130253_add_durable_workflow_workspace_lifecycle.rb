class AddDurableWorkflowWorkspaceLifecycle < ActiveRecord::Migration[8.1]
  def change
    add_column :workflows, :workspace_lifecycle_state, :string
    add_column :workflows, :last_workspace_hostname, :string
    add_column :workflows, :last_workspace_storage_key, :string

    create_table :workflow_workspace_events do |t|
      t.references :workflow, null: false, foreign_key: true
      t.string :event_type, null: false
      t.string :hostname
      t.string :storage_key
      t.string :actor, null: false
      t.string :reason
      t.json :details
      t.timestamps
    end

    add_index :workflow_workspace_events, [ :workflow_id, :created_at, :id ],
      name: "idx_workflow_workspace_events_timeline"
    add_index :workflows, :last_workspace_storage_key

    reversible do |direction|
      direction.up do
        execute <<~SQL.squish
          UPDATE workflows
          SET last_workspace_hostname = worker_hostname,
              last_workspace_storage_key = worker_storage_key
          WHERE worker_hostname IS NOT NULL OR worker_storage_key IS NOT NULL
        SQL
      end
    end
  end
end
