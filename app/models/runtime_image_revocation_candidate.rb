class RuntimeImageRevocationCandidate < ApplicationRecord
  STATES = %w[pending applied dismissed].freeze

  belongs_to :runtime_image
  belongs_to :prior_attestation, class_name: "RuntimeImageVerificationAttestation"
  belongs_to :triggering_attestation, class_name: "RuntimeImageVerificationAttestation"

  attribute :safe_summary, :json, default: -> { {} }
  after_initialize { self.state ||= "pending" }

  validates :state, inclusion: { in: STATES }
  validates :reason_code, :detected_at, presence: true
  validates :triggering_attestation_id, uniqueness: true
  validate :attestations_bind_to_image

  private

  def attestations_bind_to_image
    return unless runtime_image

    errors.add(:prior_attestation, :invalid) if prior_attestation && prior_attestation.runtime_image_id != runtime_image_id
    errors.add(:triggering_attestation, :invalid) if triggering_attestation && triggering_attestation.runtime_image_id != runtime_image_id
  end
end
