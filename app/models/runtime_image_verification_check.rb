class RuntimeImageVerificationCheck < ApplicationRecord
  STATES = %w[pending running passed failed unavailable skipped].freeze
  FAILURE_CLASSES = %w[policy integrity infrastructure evidence verifier].freeze

  belongs_to :attempt, class_name: "RuntimeImageVerificationAttempt",
             foreign_key: :runtime_image_verification_attempt_id, inverse_of: :checks

  attr_readonly :runtime_image_verification_attempt_id, :position, :verifier_key, :required
  attribute :evidence_references, :json, default: -> { [] }

  validates :state, inclusion: { in: STATES }
  validates :failure_class, inclusion: { in: FAILURE_CLASSES }, allow_nil: true
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, uniqueness: { scope: :runtime_image_verification_attempt_id }
  validates :verifier_key, presence: true
end
