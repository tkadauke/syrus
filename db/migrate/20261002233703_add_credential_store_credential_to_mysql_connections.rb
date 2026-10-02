class AddCredentialStoreCredentialToMysqlConnections < ActiveRecord::Migration[8.1]
  def change
    add_column :mysql_connections, :credential_store_credential_id, :integer unless column_exists?(:mysql_connections, :credential_store_credential_id)
    add_index :mysql_connections, :credential_store_credential_id unless index_exists?(:mysql_connections, :credential_store_credential_id)
  end
end
