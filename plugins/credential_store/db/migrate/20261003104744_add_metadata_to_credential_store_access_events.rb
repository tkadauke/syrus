class AddMetadataToCredentialStoreAccessEvents < ActiveRecord::Migration[8.1]
  def change
    return if column_exists?(:credential_store_credential_access_events, :metadata)

    add_column :credential_store_credential_access_events, :metadata, :json
    reversible do |dir|
      dir.up do
        execute "UPDATE credential_store_credential_access_events SET metadata = '{}' WHERE metadata IS NULL"
      end
    end
    change_column_null :credential_store_credential_access_events, :metadata, false
  end
end
