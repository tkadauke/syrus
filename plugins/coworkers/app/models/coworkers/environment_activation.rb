# Immutable history entry for one atomic environment publication. Turn
# admission resolves this record so a later publication cannot produce a
# mixed revision/image pair.
class Coworkers::EnvironmentActivation < ApplicationRecord
  self.table_name = "coworker_environment_activations"

  AUTHORITY_KINDS = %w[permission inherited].freeze
  DIGEST_FORMAT = /\Asha256:[0-9a-f]{64}\z/

  belongs_to :environment, class_name: "Coworkers::Environment", foreign_key: :coworker_environment_id,
             inverse_of: :activations
  belongs_to :revision, class_name: "Coworkers::EnvironmentRevision", foreign_key: :environment_revision_id
  belongs_to :runtime_image
  belongs_to :previous_activation, class_name: "Coworkers::EnvironmentActivation", optional: true
  belongs_to :verification_attestation, class_name: "RuntimeImageVerificationAttestation"
  belongs_to :authority_lease, class_name: "PermissionLease", optional: true
  belongs_to :inherited_from_activation, class_name: "Coworkers::EnvironmentActivation", optional: true

  attr_readonly :coworker_environment_id, :environment_revision_id, :runtime_image_id,
                :previous_activation_id, :verification_attestation_id, :authority_lease_id,
                :inherited_from_activation_id, :source_digest, :image_digest, :authority_kind,
                :actor, :activated_at

  validates :source_digest, :image_digest, format: { with: DIGEST_FORMAT }
  validates :authority_kind, inclusion: { in: AUTHORITY_KINDS }
  validates :actor, :activated_at, presence: true
  validate :immutable_bindings_match

  private

  def immutable_bindings_match
    return unless environment && revision && runtime_image && verification_attestation

    errors.add(:revision, :invalid) unless revision.coworker_environment_id == environment.id
    errors.add(:source_digest, :invalid) unless source_digest == revision.source_digest
    errors.add(:image_digest, :invalid) unless image_digest == runtime_image.digest
    errors.add(:verification_attestation, :invalid) unless verification_attestation.runtime_image_id == runtime_image.id
    if authority_kind == "inherited"
      errors.add(:inherited_from_activation, :blank) unless inherited_from_activation
      if inherited_from_activation && inherited_from_activation.source_digest != source_digest
        errors.add(:inherited_from_activation, :invalid)
      end
    end
  end
end
