class HardenAlertmanagerInvestigationsStorage < ActiveRecord::Migration[8.1]
  def up
    remove_index :alertmanager_investigations, name: "idx_alertmanager_investigations_host_time", if_exists: true

    change_column :alertmanager_investigations, :runbook_url, :text, null: false unless text_column?(:runbook_url)
    change_column :alertmanager_investigations, :host, :text, null: false unless text_column?(:host)
    change_column :alertmanager_investigations, :runbook_ref, :text unless text_column?(:runbook_ref)
    change_column :alertmanager_investigations, :runbook_path, :text unless text_column?(:runbook_path)
    add_column :alertmanager_investigations, :resolution_status, :string, null: false, default: "created", if_not_exists: true
    add_column :alertmanager_investigations, :resolution_error, :text, if_not_exists: true

    add_index :alertmanager_investigations,
              [ :host, :created_at ],
              name: "idx_alertmanager_investigations_host_time",
              length: { host: 191 },
              if_not_exists: true
  end

  def down
    remove_index :alertmanager_investigations, name: "idx_alertmanager_investigations_host_time", if_exists: true
    remove_column :alertmanager_investigations, :resolution_error, if_exists: true
    remove_column :alertmanager_investigations, :resolution_status, if_exists: true
    change_column :alertmanager_investigations, :runbook_url, :string, null: false
    change_column :alertmanager_investigations, :host, :string, null: false
    change_column :alertmanager_investigations, :runbook_ref, :string
    change_column :alertmanager_investigations, :runbook_path, :string
    add_index :alertmanager_investigations,
              [ :host, :created_at ],
              name: "idx_alertmanager_investigations_host_time",
              if_not_exists: true
  end

  private

  def text_column?(name)
    connection.columns(:alertmanager_investigations).find { |column| column.name == name.to_s }&.type == :text
  end
end
