class CreateBackendExceptionEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :backend_exception_events do |t|
      t.datetime :occurred_at, null: false
      t.string :app_revision
      t.string :fingerprint, null: false
      t.string :source, null: false
      t.string :role
      t.string :hostname
      t.integer :pid
      t.string :request_id
      t.string :exception_class, null: false
      t.text :message, null: false
      t.text :backtrace
      t.string :controller
      t.string :action
      t.string :method
      t.text :path
      t.integer :status
      t.string :job_class
      t.string :active_job_id
      t.string :queue_name
      t.integer :executions
      t.references :job, foreign_key: true
      t.references :workflow, foreign_key: true
      t.references :run, foreign_key: true
      t.json :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :backend_exception_events, [ :occurred_at, :id ], name: "index_backend_exception_events_on_occurred_id"
    add_index :backend_exception_events, [ :fingerprint, :occurred_at ], name: "index_backend_exception_events_on_fingerprint_time"
    add_index :backend_exception_events, [ :app_revision, :occurred_at ], name: "index_backend_exception_events_on_revision_time"
    add_index :backend_exception_events, [ :source, :occurred_at ], name: "index_backend_exception_events_on_source_time"
    add_index :backend_exception_events, [ :exception_class, :occurred_at ], name: "index_backend_exception_events_on_class_time"
    add_index :backend_exception_events, [ :path, :occurred_at ], name: "index_backend_exception_events_on_path_time", length: { path: 255 }
  end
end
