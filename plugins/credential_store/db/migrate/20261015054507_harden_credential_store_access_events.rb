class HardenCredentialStoreAccessEvents < ActiveRecord::Migration[8.1]
  def up
    change_column_null :credential_store_credential_access_events, :credential_id, true
    add_column :credential_store_credential_access_events, :lease_id, :string
    add_index :credential_store_credential_access_events, %i[action lease_id], unique: true
    add_reference :credential_store_credential_access_events, :lease_event, index: { unique: true }
  end

  def down
    remove_reference :credential_store_credential_access_events, :lease_event, index: { unique: true }
    remove_index :credential_store_credential_access_events, %i[action lease_id]
    remove_column :credential_store_credential_access_events, :lease_id
    change_column_null :credential_store_credential_access_events, :credential_id, false
  end
end
