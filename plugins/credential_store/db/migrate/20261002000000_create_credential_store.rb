class CreateCredentialStore < ActiveRecord::Migration[8.1]
  def change
    create_table :credential_store_credentials, if_not_exists: true do |t|
      t.string :name, null: false
      t.text :description
      t.string :credential_type, null: false
      t.string :scope_type, null: false
      t.bigint :scope_id
      t.references :created_by, null: false
      t.references :owner_user
      t.text :payload, null: false
      t.json :safe_metadata, null: false
      t.json :target_constraints, null: false
      t.json :allowed_surfaces, null: false
      t.json :allowed_tools, null: false
      t.datetime :expires_at
      t.datetime :last_rotated_at
      t.datetime :revoked_at
      t.timestamps
    end

    unless index_exists?(:credential_store_credentials, %i[scope_type scope_id credential_type], name: "idx_credential_store_credentials_scope_type")
      add_index :credential_store_credentials,
        %i[scope_type scope_id credential_type],
        name: "idx_credential_store_credentials_scope_type"
    end
    add_index :credential_store_credentials, :revoked_at unless index_exists?(:credential_store_credentials, :revoked_at)
    add_index :credential_store_credentials, :expires_at unless index_exists?(:credential_store_credentials, :expires_at)

    create_table :credential_store_credential_access_events, if_not_exists: true do |t|
      t.references :credential, null: false
      t.references :user
      t.references :repository
      t.references :job
      t.references :workflow
      t.references :run
      t.references :chat_session
      t.string :tool_name
      t.string :surface, null: false
      t.string :action, null: false
      t.string :purpose
      t.string :result, null: false
      t.string :denial_reason
      t.timestamps
    end

    unless index_exists?(:credential_store_credential_access_events, %i[credential_id created_at id], name: "idx_credential_store_access_credential_time")
      add_index :credential_store_credential_access_events,
        %i[credential_id created_at id],
        name: "idx_credential_store_access_credential_time"
    end
    unless index_exists?(:credential_store_credential_access_events, %i[run_id created_at id], name: "idx_credential_store_access_run_time")
      add_index :credential_store_credential_access_events,
        %i[run_id created_at id],
        name: "idx_credential_store_access_run_time"
    end
    unless index_exists?(:credential_store_credential_access_events, %i[chat_session_id created_at id], name: "idx_credential_store_access_chat_time")
      add_index :credential_store_credential_access_events,
        %i[chat_session_id created_at id],
        name: "idx_credential_store_access_chat_time"
    end
  end
end
