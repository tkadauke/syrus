class PreviewEnvironment < ApplicationRecord
  include AASM
  include RecordsStateTransitions

  STATES = %w[ starting seeding running stopping stopped failed ].freeze
  ACTIVE_STATES = %w[ starting seeding running stopping ].freeze
  ACTIVE_OWNER_CONFLICT_MESSAGE = "already has an active preview environment"

  DEFAULT_PORT_MIN = 20_000
  DEFAULT_PORT_MAX = 29_999
  DEFAULT_TTL_MINUTES = 10

  belongs_to :job, optional: true
  belongs_to :repository, optional: true

  validates :state, presence: true, inclusion: { in: STATES }
  validates :project_id, format: { with: /\A[A-Za-z0-9_-]+\z/ }, allow_blank: true
  validates :error_message, absence: true, unless: :failed?
  validates :active_owner_key, uniqueness: true, allow_nil: true
  validate :exactly_one_owner
  validate :only_one_active_per_owner, on: :create

  before_validation :sync_active_owner_key

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
  def preview_url(base_domain) = "http://preview-#{id}.#{base_domain}"

  # Job-scoped previews resolve the repository through the Job; a
  # repository-scoped preview (no Job) carries repository_id directly.
  def effective_repository = job&.repository || repository

  def touch_activity!
    update_columns(last_activity_at: Time.current, expires_at: DEFAULT_TTL_MINUTES.minutes.from_now)
  end

  private

  def exactly_one_owner
    return if job_id.present? ^ repository_id.present?

    errors.add(:base, "must belong to exactly one of job or repository")
  end

  def only_one_active_per_owner
    scope = job_id.present? ? PreviewEnvironment.where(job_id: job_id) : PreviewEnvironment.where(repository_id: repository_id, job_id: nil)
    if scope.where(state: ACTIVE_STATES).exists?
      errors.add(:base, ACTIVE_OWNER_CONFLICT_MESSAGE)
    end
  end

  # Mirrors RuntimeControlLease#active_group_key: non-nil only while this
  # preview is active, so historical stopped/failed rows never occupy the
  # owner's one live slot.
  def sync_active_owner_key
    self.active_owner_key =
      if active? && job_id.present?
        "job:#{job_id}"
      elsif active? && repository_id.present?
        "repository:#{repository_id}"
      end
  end
end
