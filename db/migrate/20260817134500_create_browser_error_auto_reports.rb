class CreateBrowserErrorAutoReports < ActiveRecord::Migration[8.1]
  def change
    create_table :browser_error_auto_reports do |t|
      t.references :browser_error_event, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.references :job, foreign_key: true
      t.string :app_revision, null: false
      t.string :fingerprint, null: false
      t.string :status, null: false, default: "pending"
      t.text :issue_url
      t.text :error_message

      t.timestamps
    end

    add_index :browser_error_auto_reports, [ :fingerprint, :app_revision ], unique: true, name: "index_browser_error_auto_reports_on_fingerprint_revision"
    add_index :browser_error_auto_reports, [ :status, :created_at ], name: "index_browser_error_auto_reports_on_status_created_at"
  end
end
