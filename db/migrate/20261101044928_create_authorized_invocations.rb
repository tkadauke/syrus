class CreateAuthorizedInvocations < ActiveRecord::Migration[8.1]
  def up
    create_table :authorized_invocations, if_not_exists: true do |t|
      t.references :pending_action_item, null: false, foreign_key: false, index: false
      t.references :authority, polymorphic: true, null: true, index: false
      t.string :invocation_fingerprint, null: false
      t.string :tool_name, null: false
      t.json :execution_authority, null: false
      t.json :audit_payload, null: false
      t.string :state, null: false, default: "issued"
      t.string :claim_key
      t.references :claimed_by, polymorphic: true, null: true
      t.datetime :claimed_at
      t.datetime :executed_at
      t.string :result_status
      t.references :result, polymorphic: true, null: true
      t.datetime :invalidated_at
      t.text :invalidation_reason
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end

    add_index :authorized_invocations, :pending_action_item_id,
      unique: true, name: "idx_authorized_invocations_item_unique" unless index_exists?(:authorized_invocations, name: "idx_authorized_invocations_item_unique")
    add_index :authorized_invocations, :claim_key,
      unique: true, where: "claim_key IS NOT NULL", name: "idx_authorized_invocations_claim_key_unique" unless index_exists?(:authorized_invocations, name: "idx_authorized_invocations_claim_key_unique")
    add_index :authorized_invocations, [ :authority_type, :authority_id, :state ],
      name: "idx_authorized_invocations_authority_state" unless index_exists?(:authorized_invocations, name: "idx_authorized_invocations_authority_state")
    add_index :authorized_invocations, [ :invocation_fingerprint, :state ],
      name: "idx_authorized_invocations_fingerprint_state" unless index_exists?(:authorized_invocations, name: "idx_authorized_invocations_fingerprint_state")
  end

  def down
    drop_table :authorized_invocations, if_exists: true
  end
end
