class CreateApprovalProviderDelegations < ActiveRecord::Migration[8.1]
  def up
    create_table :approval_provider_delegations, if_not_exists: true do |t|
      t.references :owner_user, null: false, foreign_key: { to_table: :users }
      t.string :provider_key, null: false
      t.string :capability, null: false
      t.string :resource_type, null: false
      t.json :resource_scope, null: false
      t.json :excluded_effects, null: false
      t.datetime :revoked_at
      t.references :revoked_by_user, null: true, foreign_key: { to_table: :users }
      t.integer :lock_version, null: false, default: 0

      t.timestamps
    end

    add_index :approval_provider_delegations,
      [ :owner_user_id, :provider_key, :capability, :revoked_at ],
      name: "idx_approval_delegations_active", if_not_exists: true
  end

  def down
    drop_table :approval_provider_delegations, if_exists: true
  end
end
