class HardenAlertmanagerInvestigationsStorage < ActiveRecord::Migration[8.1]
  def up
    remove_index :alertmanager_investigations, name: "idx_alertmanager_investigations_host_time", if_exists: true

    change_column :alertmanager_investigations, :runbook_url, :text, null: false unless text_column?(:runbook_url)
    change_column :alertmanager_investigations, :host, :text, null: false unless text_column?(:host)
    change_column :alertmanager_investigations, :runbook_ref, :text unless text_column?(:runbook_ref)
    change_column :alertmanager_investigations, :runbook_path, :text unless text_column?(:runbook_path)
    unless column_exists?(:alertmanager_investigations, :resolution_status)
      add_column :alertmanager_investigations, :resolution_status, :string, null: false, default: "created"
    end
    add_column :alertmanager_investigations, :resolution_error, :text unless column_exists?(:alertmanager_investigations, :resolution_error)
    backfill_canonical_hosts

    unless index_exists?(:alertmanager_investigations, [ :host, :created_at ], name: "idx_alertmanager_investigations_host_time")
      add_index :alertmanager_investigations,
                [ :host, :created_at ],
                name: "idx_alertmanager_investigations_host_time",
                length: { host: 191 }
    end
  end

  def down
    remove_index :alertmanager_investigations, name: "idx_alertmanager_investigations_host_time", if_exists: true
    remove_column :alertmanager_investigations, :resolution_error if column_exists?(:alertmanager_investigations, :resolution_error)
    remove_column :alertmanager_investigations, :resolution_status if column_exists?(:alertmanager_investigations, :resolution_status)
    change_column :alertmanager_investigations, :runbook_url, :string, null: false
    change_column :alertmanager_investigations, :host, :string, null: false
    change_column :alertmanager_investigations, :runbook_ref, :string
    change_column :alertmanager_investigations, :runbook_path, :string
    unless index_exists?(:alertmanager_investigations, [ :host, :created_at ], name: "idx_alertmanager_investigations_host_time")
      add_index :alertmanager_investigations,
                [ :host, :created_at ],
                name: "idx_alertmanager_investigations_host_time"
    end
  end

  private

  def text_column?(name)
    connection.columns(:alertmanager_investigations).find { |column| column.name == name.to_s }&.type == :text
  end

  def backfill_canonical_hosts
    investigation_class = Class.new(ActiveRecord::Base) do
      self.table_name = "alertmanager_investigations"
    end
    investigation_class.reset_column_information

    investigation_class.find_each do |investigation|
      canonical_host = canonicalize_host(investigation.host)
      investigation.update_columns(host: canonical_host) if canonical_host != investigation.host
    end
  end

  def canonicalize_host(host)
    value = host.to_s.strip.downcase
    bracketed = value.match(/\A\[(.+)\](?::\d+)?\z/)
    return bracketed[1] if bracketed
    return value unless value.count(":") == 1

    value.sub(/:\d+\z/, "")
  end
end
