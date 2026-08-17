class CreateBrowserErrorEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :browser_error_events do |t|
      t.references :user, null: false, foreign_key: true
      t.datetime :occurred_at, null: false
      t.string :app_revision
      t.string :fingerprint, null: false
      t.string :name
      t.text :message, null: false
      t.text :stack
      t.text :component_stack
      t.text :url
      t.string :path
      t.string :route_id
      t.json :route_params, null: false, default: {}
      t.string :trace_id
      t.text :user_agent
      t.json :viewport, null: false, default: {}
      t.json :feature_flags, null: false, default: {}
      t.json :recent_api_requests, null: false, default: []
      t.json :recent_errors, null: false, default: []
      t.json :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :browser_error_events, [ :occurred_at, :id ], name: "index_browser_error_events_on_occurred_id"
    add_index :browser_error_events, [ :fingerprint, :occurred_at ], name: "index_browser_error_events_on_fingerprint_time"
    add_index :browser_error_events, [ :app_revision, :occurred_at ], name: "index_browser_error_events_on_revision_time"
    add_index :browser_error_events, [ :path, :occurred_at ], name: "index_browser_error_events_on_path_time"
  end
end
