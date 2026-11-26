class AddLifecycleToRuntimeImageVerificationEvidence < ActiveRecord::Migration[8.1]
  def up
    add_column :runtime_image_verification_attempts, :evidence_digest, :string, limit: 71 unless column_exists?(:runtime_image_verification_attempts, :evidence_digest)
    add_column :runtime_image_verification_attempts, :attestation_digest, :string, limit: 71 unless column_exists?(:runtime_image_verification_attempts, :attestation_digest)
    add_column :runtime_image_verification_attempts, :expires_at, :datetime unless column_exists?(:runtime_image_verification_attempts, :expires_at)
    add_index :runtime_image_verification_attempts, :expires_at, name: "idx_ri_verification_expiry" unless index_exists?(:runtime_image_verification_attempts, :expires_at, name: "idx_ri_verification_expiry")
  end

  def down
    remove_index :runtime_image_verification_attempts, name: "idx_ri_verification_expiry" if index_exists?(:runtime_image_verification_attempts, name: "idx_ri_verification_expiry")
    remove_column :runtime_image_verification_attempts, :expires_at if column_exists?(:runtime_image_verification_attempts, :expires_at)
    remove_column :runtime_image_verification_attempts, :attestation_digest if column_exists?(:runtime_image_verification_attempts, :attestation_digest)
    remove_column :runtime_image_verification_attempts, :evidence_digest if column_exists?(:runtime_image_verification_attempts, :evidence_digest)
  end
end
