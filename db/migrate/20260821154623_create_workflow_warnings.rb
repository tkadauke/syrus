class CreateWorkflowWarnings < ActiveRecord::Migration[8.1]
  def up
    create_table :workflow_warnings, if_not_exists: true do |t|
      t.integer :job_id,         null: false
      t.integer :workflow_id,    null: false
      t.integer :step_id
      t.integer :created_job_id

      t.string :kind,     null: false
      t.string :severity, null: false, default: "medium"
      t.string :title,    null: false
      t.string :state,    null: false, default: "pending"

      t.text :suggested_prompt

      t.timestamps
    end

    # JSON columns cannot have a default value on MySQL 8.
    add_column :workflow_warnings, :evidence, :json unless column_exists?(:workflow_warnings, :evidence)

    unless index_exists?(:workflow_warnings, :job_id)
      add_index :workflow_warnings, :job_id
    end
    unless index_exists?(:workflow_warnings, :workflow_id)
      add_index :workflow_warnings, :workflow_id
    end
    unless index_exists?(:workflow_warnings, :step_id)
      add_index :workflow_warnings, :step_id
    end
    unless index_exists?(:workflow_warnings, :created_job_id)
      add_index :workflow_warnings, :created_job_id
    end
    unless index_exists?(:workflow_warnings, :state)
      add_index :workflow_warnings, :state
    end
    unless index_exists?(:workflow_warnings, :kind)
      add_index :workflow_warnings, :kind
    end
    unless index_exists?(:workflow_warnings, [ :job_id, :created_at ],
                         name: "index_workflow_warnings_on_job_id_and_created_at")
      add_index :workflow_warnings, [ :job_id, :created_at ],
                name: "index_workflow_warnings_on_job_id_and_created_at"
    end
    unless index_exists?(:workflow_warnings, [ :job_id, :state ],
                         name: "index_workflow_warnings_on_job_id_and_state")
      add_index :workflow_warnings, [ :job_id, :state ],
                name: "index_workflow_warnings_on_job_id_and_state"
    end
  end

  def down
    drop_table :workflow_warnings, if_exists: true
  end
end
