class AllowCredentiallessCredentialStoreAccessEvents < ActiveRecord::Migration[8.1]
  def up
    return unless column_exists?(:credential_store_credential_access_events, :credential_id)

    change_column_null :credential_store_credential_access_events, :credential_id, true
  end

  def down
    raise ActiveRecord::IrreversibleMigration if select_value(<<~SQL).to_i.positive?
      SELECT COUNT(*) FROM credential_store_credential_access_events WHERE credential_id IS NULL
    SQL

    change_column_null :credential_store_credential_access_events, :credential_id, false
  end
end
