class AddEventUidToOperationalLogEvents < ActiveRecord::Migration[8.1]
  def change
    add_column :operational_log_events, :event_uid, :string, limit: 64 unless column_exists?(:operational_log_events, :event_uid)

    unless index_exists?(:operational_log_events, :event_uid, name: "idx_operational_log_events_event_uid")
      add_index :operational_log_events, :event_uid, unique: true, name: "idx_operational_log_events_event_uid"
    end
  end
end
