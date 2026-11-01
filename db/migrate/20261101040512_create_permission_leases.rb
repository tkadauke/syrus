class CreatePermissionLeases < ActiveRecord::Migration[8.1]
  def up
    create_table :permission_leases, if_not_exists: true do |t|
      t.references :owner_user, null: false
      t.string :subject_selector_type, null: false
      t.string :subject_selector_id
      t.references :subject_repository, null: true
      t.string :capability, null: false
      t.string :operation
      t.string :resource_type, null: false
      t.json :resource_scope, null: false
      t.json :constraints, null: false
      t.json :effects, null: false
      t.string :duration_kind, null: false
      t.references :chat_session, null: true
      t.references :job, null: true
      t.string :invocation_fingerprint
      t.references :source, polymorphic: true, null: true
      t.references :issued_by_user, null: false
      t.references :revoked_by_user, null: true
      t.integer :max_uses
      t.integer :used_count, null: false, default: 0
      t.datetime :expires_at
      t.datetime :revoked_at
      t.integer :lock_version, null: false, default: 0

      t.timestamps
    end

    add_index :permission_leases, [ :owner_user_id, :subject_selector_type, :subject_selector_id, :revoked_at ],
      name: "idx_permission_leases_current_subject" unless index_exists?(:permission_leases,
        [ :owner_user_id, :subject_selector_type, :subject_selector_id, :revoked_at ],
        name: "idx_permission_leases_current_subject")
    add_index :permission_leases, [ :capability, :operation, :revoked_at, :expires_at ],
      name: "idx_permission_leases_current_capability" unless index_exists?(:permission_leases,
        [ :capability, :operation, :revoked_at, :expires_at ],
        name: "idx_permission_leases_current_capability")
    add_index :permission_leases, [ :subject_repository_id, :revoked_at ],
      name: "idx_permission_leases_current_repository" unless index_exists?(:permission_leases,
        [ :subject_repository_id, :revoked_at ], name: "idx_permission_leases_current_repository")
  end

  def down
    drop_table :permission_leases, if_exists: true
  end
end
