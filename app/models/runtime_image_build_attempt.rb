# One execution attempt of a RuntimeImageBuildRequest. Attempts are numbered
# from 1 and never reused; a retry is a new attempt.
class RuntimeImageBuildAttempt < ApplicationRecord
  STATES = %w[building verifying succeeded failed canceled].freeze
  ACTIVE_STATES = %w[building verifying].freeze

  belongs_to :request, class_name: "RuntimeImageBuildRequest", foreign_key: :runtime_image_build_request_id,
             inverse_of: :attempts

  validates :number, numericality: { only_integer: true, greater_than: 0 }
  validates :state, inclusion: { in: STATES }
  validates :started_at, presence: true

  scope :active, -> { where(state: ACTIVE_STATES) }
  scope :lease_expired, ->(now = Time.current) { active.where(lease_expires_at: ..now) }

  def active? = ACTIVE_STATES.include?(state)
end
