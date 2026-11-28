class RuntimeImageRevocationCandidate < ApplicationRecord
  STATES = %w[pending resolved dismissed].freeze
  belongs_to :runtime_image
  belongs_to :prior_attestation, class_name: "RuntimeImageVerificationAttestation"
  belongs_to :triggering_attestation, class_name: "RuntimeImageVerificationAttestation"
  attr_readonly :runtime_image_id, :prior_attestation_id, :triggering_attestation_id, :reason_code, :safe_summary, :detected_at
  attribute :safe_summary, :json, default: -> { {} }
  validates :reason_code, :detected_at, presence: true
  validates :state, inclusion: { in: STATES }
  validates :triggering_attestation_id, uniqueness: true
  validate :bindings_match
  private
  def bindings_match
    ids = [ prior_attestation&.runtime_image_id, triggering_attestation&.runtime_image_id ].compact
    errors.add(:runtime_image, :invalid) unless ids.all? { |id| id == runtime_image_id }
  end
end
