class MaintenanceTask < ApplicationRecord
  STATES = %w[pending running paused succeeded failed cancelled dismissed not_needed].freeze
  ACTIVE_STATES = %w[pending running paused failed].freeze
  RECURRENCES = %w[one_off repeatable].freeze
  CATEGORIES = %w[backfill index repair cleanup integration].freeze

  belongs_to :requested_by_user, class_name: "User", optional: true
  belongs_to :dismissed_by_user, class_name: "User", optional: true
  has_many :events, class_name: "MaintenanceTaskEvent", dependent: :destroy

  validates :definition_key, :task_key, :state, :recurrence, :category, :title,
            :summary, :trigger_kind, :trigger_key, :required_role, presence: true
  validates :state, inclusion: { in: STATES }
  validates :recurrence, inclusion: { in: RECURRENCES }
  validates :category, inclusion: { in: CATEGORIES }
  validates :task_key, uniqueness: true
  validates :batch_size, numericality: { only_integer: true, greater_than: 0 }
  validates :max_parallelism, numericality: { only_integer: true, greater_than: 0 }

  before_validation :default_json_columns

  scope :visible_in_sidebar, -> {
    where(state: %w[pending running paused failed])
      .where(dismissed_at: nil)
      .order(Arel.sql("CASE state WHEN 'running' THEN 0 WHEN 'failed' THEN 1 WHEN 'paused' THEN 2 ELSE 3 END"), :created_at)
  }

  scope :active_or_failed, -> { where(state: ACTIVE_STATES) }

  def definition
    MaintenanceTasks::Registry.fetch(definition_key)
  end

  def progress_percent
    return 0 if total_units.to_i <= 0

    ((completed_units.to_f / total_units) * 100).clamp(0, 100).round
  end

  def runnable?
    state.in?(%w[pending paused failed])
  end

  def terminal?
    state.in?(%w[succeeded cancelled not_needed])
  end

  def log!(message, level: "info", step_key: current_step_key, step_title: current_step_title, metadata: {}, units_done: completed_units, units_total: total_units)
    events.create!(
      level: level,
      step_key: step_key,
      step_title: step_title,
      message: message,
      metadata: metadata || {},
      units_done: units_done,
      units_total: units_total
    )
  end

  private

  def default_json_columns
    self.checkpoint ||= {}
    self.metadata ||= {}
  end
end
