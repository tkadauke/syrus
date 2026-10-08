class CreateAlertmanagerInvestigations < ActiveRecord::Migration[8.1]
  def change
    create_table :alertmanager_investigations, if_not_exists: true do |t|
      t.string :fingerprint, null: false
      t.string :host, null: false
      t.string :runbook_url, null: false
      t.string :runbook_repository
      t.string :runbook_ref
      t.string :runbook_path
      t.json :alert_payload
      t.references :repository, foreign_key: false
      t.references :job, foreign_key: false

      t.timestamps
    end

    unless index_exists?(:alertmanager_investigations, [ :fingerprint, :created_at ], name: "idx_alertmanager_investigations_fingerprint_time")
      add_index :alertmanager_investigations,
                [ :fingerprint, :created_at ],
                name: "idx_alertmanager_investigations_fingerprint_time"
    end

    unless index_exists?(:alertmanager_investigations, [ :host, :created_at ], name: "idx_alertmanager_investigations_host_time")
      add_index :alertmanager_investigations,
                [ :host, :created_at ],
                name: "idx_alertmanager_investigations_host_time"
    end
  end
end
