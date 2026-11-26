class RuntimeImageRevocationCandidate < ApplicationRecord
  TRIGGERS = %w[attestation_expired policy_changed vulnerability_data_changed].freeze
  SEVERITIES = %w[critical high].freeze
  STATES = %w[open resolved dismissed].freeze

  belongs_to :runtime_image
  belongs_to :attempt, class_name: "RuntimeImageVerificationAttempt",
             foreign_key: :runtime_image_verification_attempt_id, inverse_of: :revocation_candidate

  validates :runtime_image_verification_attempt_id, uniqueness: true
  validates :trigger_kind, inclusion: { in: TRIGGERS }
  validates :severity, inclusion: { in: SEVERITIES }
  validates :state, inclusion: { in: STATES }
  validates :reason, :detected_at, presence: true
  validate :attempt_matches_image

  private

  def attempt_matches_image
    errors.add(:attempt, :invalid) if attempt && runtime_image_id != attempt.runtime_image_id
  end
end
