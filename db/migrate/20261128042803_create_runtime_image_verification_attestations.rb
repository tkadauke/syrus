class CreateRuntimeImageVerificationAttestations < ActiveRecord::Migration[8.1]
  def up
    create_table :runtime_image_verification_attestations, if_not_exists: true do |t|
      t.references :runtime_image, null: false, foreign_key: false, index: false
      t.references :runtime_image_verification_attempt, null: false, foreign_key: false, index: false
      t.string :image_digest, :policy_digest, :evidence_digest, null: false, limit: 71
      t.string :outcome, null: false, limit: 24
      t.json :safe_summary
      t.string :vulnerability_database_version, limit: 191
      t.datetime :issued_at, :expires_at, null: false
      t.datetime :invalidated_at, :exact_evidence_purged_at
      t.string :invalidation_reason, limit: 100
      t.timestamps
    end
    add_index :runtime_image_verification_attestations, :runtime_image_verification_attempt_id, unique: true, name: "idx_runtime_image_attestations_attempt" unless index_exists?(:runtime_image_verification_attestations, :runtime_image_verification_attempt_id, name: "idx_runtime_image_attestations_attempt")
    add_index :runtime_image_verification_attestations, [ :outcome, :invalidated_at, :expires_at ], name: "idx_runtime_image_attestations_validity" unless index_exists?(:runtime_image_verification_attestations, [ :outcome, :invalidated_at, :expires_at ], name: "idx_runtime_image_attestations_validity")
    add_index :runtime_image_verification_attestations, [ :runtime_image_id, :issued_at ], name: "idx_runtime_image_attestations_image_issued" unless index_exists?(:runtime_image_verification_attestations, [ :runtime_image_id, :issued_at ], name: "idx_runtime_image_attestations_image_issued")
    create_table :runtime_image_revocation_candidates, if_not_exists: true do |t|
      t.references :runtime_image, null: false, foreign_key: false, index: false
      t.references :prior_attestation, null: false, foreign_key: false, index: false
      t.references :triggering_attestation, null: false, foreign_key: false, index: false
      t.string :reason_code, null: false, limit: 100
      t.json :safe_summary
      t.string :state, null: false, default: "pending", limit: 24
      t.datetime :detected_at, null: false
      t.datetime :resolved_at
      t.timestamps
    end
    add_index :runtime_image_revocation_candidates, :prior_attestation_id, name: "idx_runtime_image_revocations_prior" unless index_exists?(:runtime_image_revocation_candidates, :prior_attestation_id, name: "idx_runtime_image_revocations_prior")
    add_index :runtime_image_revocation_candidates, :triggering_attestation_id, unique: true, name: "idx_runtime_image_revocations_trigger" unless index_exists?(:runtime_image_revocation_candidates, :triggering_attestation_id, name: "idx_runtime_image_revocations_trigger")
    add_index :runtime_image_revocation_candidates, [ :runtime_image_id, :state ], name: "idx_runtime_image_revocation_candidates_state" unless index_exists?(:runtime_image_revocation_candidates, [ :runtime_image_id, :state ], name: "idx_runtime_image_revocation_candidates_state")
  end

  def down
    drop_table :runtime_image_revocation_candidates, if_exists: true
    drop_table :runtime_image_verification_attestations, if_exists: true
  end
end
