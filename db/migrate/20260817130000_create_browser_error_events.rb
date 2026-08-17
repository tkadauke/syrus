class CreateBrowserErrorEvents < ActiveRecord::Migration[8.1]
  # JSON columns carry no DB default: MySQL 8 rejects a literal default on
  # JSON/TEXT/BLOB ("BLOB, TEXT, GEOMETRY or JSON column ... can't have a
  # default value"), and Rails emits exactly that literal for `default: {}`.
  # SQLite accepts it, so this only surfaces at deploy time. The model already
  # supplies the values through `attribute :col, :json, default: -> { {} }`
  # plus `normalize_payload`, so `null: false` holds without a DB default.
  def change
    create_table :browser_error_events, if_not_exists: true do |t|
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
      t.json :route_params, null: false
      t.string :trace_id
      t.text :user_agent
      t.json :viewport, null: false
      t.json :feature_flags, null: false
      t.json :recent_api_requests, null: false
      t.json :recent_errors, null: false
      t.json :metadata, null: false

      t.timestamps
    end

    add_index :browser_error_events, [ :occurred_at, :id ], name: "index_browser_error_events_on_occurred_id" unless index_exists?(:browser_error_events, [ :occurred_at, :id ])
    add_index :browser_error_events, [ :fingerprint, :occurred_at ], name: "index_browser_error_events_on_fingerprint_time" unless index_exists?(:browser_error_events, [ :fingerprint, :occurred_at ])
    add_index :browser_error_events, [ :app_revision, :occurred_at ], name: "index_browser_error_events_on_revision_time" unless index_exists?(:browser_error_events, [ :app_revision, :occurred_at ])
    add_index :browser_error_events, [ :path, :occurred_at ], name: "index_browser_error_events_on_path_time" unless index_exists?(:browser_error_events, [ :path, :occurred_at ])
  end
end
