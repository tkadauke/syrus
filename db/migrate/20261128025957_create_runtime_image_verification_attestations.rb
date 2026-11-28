class CreateRuntimeImageVerificationAttestations < ActiveRecord::Migration[8.1]
  def up
    create_table :runtime_image_verification_attestations, if_not_exists: true do |t|
      t.references :runtime_image, null: false, foreign_key: false, index: false
      t.references :runtime_image_verification_attempt, null: false, foreign_key: false, index: false
      t.string :image_digest, limit: 71, null: false
      t.string :policy_digest, limit: 71, null: false
      t.string :evidence_digest, limit: 71, null: false
      t.string :outcome, limit: 24, null: false
      t.json :safe_summary
      t.string :vulnerability_database_version, limit: 191
      t.datetime :issued_at, null: false
      t.datetime :expires_at, null: false
      t.datetime :invalidated_at
      t.string :invalidation_reason, limit: 100
      t.datetime :exact_evidence_purged_at
      t.timestamps
    end
    add_index :runtime_image_verification_attestations, :runtime_image_verification_attempt_id, unique: true, name: "idx_ri_attestations_attempt" unless index_exists?(:runtime_image_verification_attestations, :runtime_image_verification_attempt_id, name: "idx_ri_attestations_attempt")
    add_index :runtime_image_verification_attestations, %i[runtime_image_id issued_at], name: "idx_ri_attestations_image_issued" unless index_exists?(:runtime_image_verification_attestations, %i[runtime_image_id issued_at], name: "idx_ri_attestations_image_issued")
    add_index :runtime_image_verification_attestations, %i[outcome expires_at], name: "idx_ri_attestations_expiry" unless index_exists?(:runtime_image_verification_attestations, %i[outcome expires_at], name: "idx_ri_attestations_expiry")

    create_table :runtime_image_revocation_candidates, if_not_exists: true do |t|
      t.references :runtime_image, null: false, foreign_key: false, index: false
      t.references :prior_attestation, null: false, foreign_key: false, index: false
      t.references :triggering_attestation, null: false, foreign_key: false, index: false
      t.string :reason_code, limit: 64, null: false
      t.json :safe_summary
      t.string :state, limit: 24, default: "pending", null: false
      t.datetime :detected_at, null: false
      t.datetime :resolved_at
      t.timestamps
    end
    add_index :runtime_image_revocation_candidates, %i[runtime_image_id state], name: "idx_ri_revocation_candidates_state" unless index_exists?(:runtime_image_revocation_candidates, %i[runtime_image_id state], name: "idx_ri_revocation_candidates_state")
    add_index :runtime_image_revocation_candidates, :triggering_attestation_id, unique: true, name: "idx_ri_revocation_trigger" unless index_exists?(:runtime_image_revocation_candidates, :triggering_attestation_id, name: "idx_ri_revocation_trigger")
  end

  def down
    drop_table :runtime_image_revocation_candidates, if_exists: true
    drop_table :runtime_image_verification_attestations, if_exists: true
  end
end
