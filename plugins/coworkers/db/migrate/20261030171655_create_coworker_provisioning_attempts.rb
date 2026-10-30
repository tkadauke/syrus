class CreateCoworkerProvisioningAttempts < ActiveRecord::Migration[8.1]
  def change
    create_table :coworker_provisioning_attempts, if_not_exists: true do |t|
      t.references :owner_user, null: false
      t.references :coworker
      t.string :idempotency_key, null: false
      t.string :remote_owner, null: false
      t.string :remote_name, null: false
      t.string :handle, null: false
      t.string :branch, null: false
      t.string :expected_seeded_commit
      t.string :state, null: false, default: "provisioning"
      t.integer :retry_count, null: false, default: 0
      t.text :last_error
      t.datetime :seeded_at
      t.datetime :completed_at
      t.datetime :cleanup_started_at
      t.datetime :cleaned_at
      t.datetime :manual_attention_at
      t.datetime :acknowledged_at
      t.references :acknowledged_by
      t.timestamps
    end

    add_index :coworker_provisioning_attempts, [ :owner_user_id, :idempotency_key ], unique: true, name: "idx_coworker_provisioning_attempts_idempotency" unless index_exists?(:coworker_provisioning_attempts, [ :owner_user_id, :idempotency_key ], name: "idx_coworker_provisioning_attempts_idempotency")
    add_index :coworker_provisioning_attempts, [ :state, :updated_at ], name: "idx_coworker_provisioning_attempts_reconciliation" unless index_exists?(:coworker_provisioning_attempts, [ :state, :updated_at ], name: "idx_coworker_provisioning_attempts_reconciliation")
  end
end
