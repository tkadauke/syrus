class HardenCredentialStoreAccessEvents < ActiveRecord::Migration[8.1]
  LEASE_ID_INDEX = "idx_credential_store_access_events_lease_id"
  COMPLETION_INDEX = "idx_credential_store_access_events_completion"

  def up
    table = :credential_store_credential_access_events
    add_column table, :lease_id, :string unless column_exists?(table, :lease_id)
    add_index table, :lease_id, unique: true, name: LEASE_ID_INDEX unless index_exists?(table, :lease_id, name: LEASE_ID_INDEX)
    add_reference table, :completion_of_event, index: false unless column_exists?(table, :completion_of_event_id)
    add_index table, :completion_of_event_id, unique: true, name: COMPLETION_INDEX unless index_exists?(table, :completion_of_event_id, name: COMPLETION_INDEX)
  end

  def down
    table = :credential_store_credential_access_events
    remove_index table, name: COMPLETION_INDEX if index_exists?(table, :completion_of_event_id, name: COMPLETION_INDEX)
    remove_reference table, :completion_of_event if column_exists?(table, :completion_of_event_id)
    remove_index table, name: LEASE_ID_INDEX if index_exists?(table, :lease_id, name: LEASE_ID_INDEX)
    remove_column table, :lease_id if column_exists?(table, :lease_id)
  end
end
