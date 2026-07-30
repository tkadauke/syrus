class PreviewEnvironment < ApplicationRecord
  include AASM
  include RecordsStateTransitions

  STATES = %w[ starting seeding running stopping stopped failed ].freeze
  ACTIVE_STATES = %w[ starting seeding running stopping ].freeze

  DEFAULT_PORT_MIN = 20_000
  DEFAULT_PORT_MAX = 29_999
  DEFAULT_TTL_MINUTES = 10

  belongs_to :job

  validates :state, presence: true, inclusion: { in: STATES }
  validates :error_message, absence: true, unless: :failed?
  validate :only_one_active_per_job, on: :create

  scope :active, -> { where(state: ACTIVE_STATES) }
  scope :expired, -> { where(state: "running").where("expires_at IS NOT NULL AND expires_at <= ?", Time.current) }

  aasm column: :state, whiny_transitions: false do
    after_all_transitions :record_state_transition!

    state :starting, initial: true
    state :seeding, :running, :stopping, :stopped, :failed

    event :begin_seeding do
      transitions from: :starting, to: :seeding
    end

    event :mark_running do
      transitions from: :seeding, to: :running, after: -> { touch_activity! }
    end

    event :begin_stopping do
      transitions from: %i[ starting seeding running ], to: :stopping
    end

    event :mark_stopped do
      transitions from: :stopping, to: :stopped
    end

    event :fail do
      transitions from: %i[ starting seeding running stopping ], to: :failed
    end
  end

  def active? = ACTIVE_STATES.include?(state)
  def preview_url(base_domain) = "http://preview-#{job_id}.#{base_domain}"

  def touch_activity!
    update_columns(last_activity_at: Time.current, expires_at: DEFAULT_TTL_MINUTES.minutes.from_now)
  end

  private

  def only_one_active_per_job
    if PreviewEnvironment.where(job_id: job_id, state: ACTIVE_STATES).exists?
      errors.add(:job, "already has an active preview environment")
    end
  end
end
