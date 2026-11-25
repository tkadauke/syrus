# One execution attempt of a RuntimeImageBuildRequest. Attempts are numbered
# from 1 and never reused; a retry is a new attempt.
class RuntimeImageBuildAttempt < ApplicationRecord
  STATES = %w[building verifying succeeded failed canceled].freeze
  ACTIVE_STATES = %w[building verifying].freeze

  belongs_to :request, class_name: "RuntimeImageBuildRequest", foreign_key: :runtime_image_build_request_id,
             inverse_of: :attempts
  has_one :evidence, class_name: "RuntimeImageBuildEvidence", foreign_key: :runtime_image_build_attempt_id,
          inverse_of: :attempt, dependent: :destroy

  validates :number, numericality: { only_integer: true, greater_than: 0 }
  validates :state, inclusion: { in: STATES }
  validates :started_at, presence: true

  scope :active, -> { where(state: ACTIVE_STATES) }
  scope :lease_expired, ->(now = Time.current) { active.where(lease_expires_at: ..now) }
  # Active for longer than +max_runtime+ regardless of heartbeats.
  scope :overdue, ->(now = Time.current, max_runtime: RuntimeImages::Builds::Config.max_attempt_runtime) { active.where(started_at: ..(now - max_runtime)) }

  def active? = ACTIVE_STATES.include?(state)
end
