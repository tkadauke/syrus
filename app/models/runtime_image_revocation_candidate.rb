class RuntimeImageRevocationCandidate < ApplicationRecord
  STATES = %w[pending applied dismissed].freeze

  belongs_to :runtime_image
  belongs_to :prior_attestation, class_name: "RuntimeImageVerificationAttestation"
  belongs_to :triggering_attestation, class_name: "RuntimeImageVerificationAttestation"

  attribute :safe_summary, :json, default: -> { {} }
  validates :state, inclusion: { in: STATES }
  validates :reason_code, :detected_at, presence: true
  validates :triggering_attestation_id, uniqueness: true
end
