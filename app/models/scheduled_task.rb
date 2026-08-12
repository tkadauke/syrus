class ScheduledTask < ApplicationRecord
  include AutoApproveModes

  KINDS = %w[ cron one_shot ].freeze
  STATES = %w[ scheduled paused auto_paused fired ].freeze
  PAUSE_STATES = { "operator" => "paused", "auto" => "auto_paused" }.freeze
  PR_PILEUP_POLICIES = %w[ skip pile replace ].freeze
  MIN_CRON_INTERVAL = 1.hour

  belongs_to :user
  belongs_to :repository
  belongs_to :cron_template, optional: true
  has_many :jobs, dependent: :nullify

  # Transient, not persisted. Set by the controller when the operator's
  # schedule_input previously resolved through the LLM cadence fallback, so
  # save-time canonicalization can reuse that structured intent instead of
  # calling the LLM again.
  attr_accessor :structured_intent

  scope :active, -> { where(archived_at: nil).where(state: %w[ scheduled ]) }
  scope :archived, -> { where.not(archived_at: nil) }
  scope :alive,    -> { where(archived_at: nil) }

  validates :name, presence: true, length: { maximum: 200 }
  validates :prompt, presence: true
  validates :kind, presence: true, inclusion: { in: KINDS }
  validates :state, presence: true, inclusion: { in: STATES }
  validates :pr_pileup_policy, presence: true, inclusion: { in: PR_PILEUP_POLICIES }
  validates :minute_offset, presence: true,
                            numericality: { only_integer: true, in: 0..59 }
  validates :consecutive_failure_count,
            presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  validates :schedule_expression, presence: true, if: :cron?
  validates :fire_at,         presence: true, if: :one_shot?
  validate  :schedule_expression_is_parseable_and_hourly, if: :cron?
  validate  :fire_at_is_in_the_future_at_create,      if: -> { one_shot? && new_record? }

  before_validation :canonicalize_recurring_schedule
  before_validation :seed_minute_offset_for_cron, on: :create

  def cron?
    kind == "cron"
  end

  def one_shot?
    kind == "one_shot"
  end

  def archived?
    archived_at.present?
  end

  def active?
    !archived? && state == "scheduled"
  end

  def paused?
    state == "paused"
  end

  def auto_paused?
    state == "auto_paused"
  end

  def fired?
    state == "fired"
  end

  # Compatibility alias for API consumers that still read the historical
  # hourly_cron_expression field. Scheduling itself uses schedule_expression.
  def hourly_cron_expression
    return nil unless cron?
    legacy_cron_expression.presence || cron_expression
  end

  def display_cron_expression
    cron? ? hourly_cron_expression : nil
  end

  def schedule_explanation
    return nil unless cron? && schedule_expression.present?

    Schedules::RecurringSchedule.explain(schedule_expression, timezone: schedule_timezone)
  rescue ArgumentError
    nil
  end

  # When does this task fire next, after `from`? Returns nil if it
  # won't (paused, archived, fired one_shot, malformed cron). For
  # cron tasks, the next hourly window is returned once the scheduled
  # minute has arrived.
  def next_fire_at(from: Time.current)
    return nil unless active?

    if one_shot?
      fire_at && fire_at > from ? fire_at : nil
    else
      current_window = scheduled_fire_window_start(now: from)
      return current_window if current_window.present? && !fired_in_window?(current_window)

      Schedules::RecurringSchedule.next_fire_at(schedule_expression, timezone: schedule_timezone, from: from)
    end
  rescue ArgumentError
    nil
  end

  # Has this task's current fire window arrived? Cron windows are one
  # hour wide and keyed by their UTC hour, so a poller that runs several
  # times during the same hour still sees only one intended fire.
  def due?(now: Time.current)
    return false unless active?

    if one_shot?
      fire_at.present? && fire_at <= now
    else
      window_start = scheduled_fire_window_start(now: now)
      window_start.present? && !fired_in_window?(window_start)
    end
  end

  def fire_window_start(now: Time.current, manual: false)
    if one_shot?
      fire_at || now
    elsif manual
      now.utc.change(min: 0, sec: 0, usec: 0)
    else
      scheduled_fire_window_start(now: now)
    end
  end

  def fired_in_window?(window_start)
    return false if last_fired_at.blank? || window_start.blank?
    last_fired_at >= window_start && last_fired_at < window_start + 1.hour
  end

  # Does this task already have a Job whose PR is still open on GitHub
  # from a prior fire? Used by pr_pileup_policy=skip to short-circuit.
  def has_open_pr?
    jobs.open_threads.where("pr_number IS NOT NULL OR external_pr_number IS NOT NULL").exists?
  end

  # Most recent Job's still-open PR ids — used by pr_pileup_policy=replace
  # to close them out before opening a fresh one.
  def open_pr_jobs
    jobs.open_threads.where.not(pr_number: nil)
  end

  # The most recently created Job from this task that opened a PR.
  # Used by Prompts::ScheduledTask to tell the agent what happened last time.
  def last_pr_job
    jobs.where.not(pr_number: nil).order(created_at: :desc).first
  end

  def soft_delete!
    update!(archived_at: Time.current)
  end

  def pause!(reason: "operator")
    update!(state: PAUSE_STATES.fetch(reason))
  end

  def resume!
    update!(state: "scheduled", consecutive_failure_count: 0)
  end

  def mark_fired_one_shot!
    update!(state: "fired")
  end

  def record_fire!(at: Time.current)
    update!(last_fired_at: at)
  end

  def record_success!(at: Time.current)
    update!(last_successful_fire_at: at, consecutive_failure_count: 0)
  end

  def record_failure!
    increment!(:consecutive_failure_count)
    return if archived?
    if consecutive_failure_count >= AppSetting.max_job_failures
      pause!(reason: "auto")
    end
  end

  private

  def scheduled_fire_window_start(now: Time.current)
    Schedules::RecurringSchedule.due_window_start(schedule_expression, timezone: schedule_timezone, now: now)
  rescue ArgumentError
    nil
  end

  def seed_minute_offset_for_cron
    return unless cron?
    return if minute_offset_changed? && !minute_offset.nil?

    self.minute_offset = SecureRandom.random_number(60)
  end

  def canonicalize_recurring_schedule
    return unless cron?

    input = schedule_input.presence || cron_expression.presence || legacy_cron_expression.presence || schedule_expression
    result = Schedules::CadencePreview.call(input: input, structured_intent: structured_intent, user: user)
    if result.valid?
      self.schedule_input = input
      self.schedule_format = result.format
      self.schedule_expression = result.expression
      self.schedule_timezone = result.timezone
      self.cron_expression = result.cron_expression
      self.legacy_cron_expression ||= result.cron_expression if result.cron_expression.present?
    else
      self.schedule_expression = nil
      errors.add(:schedule_input, result.errors.to_sentence)
    end
  end

  def schedule_expression_is_parseable_and_hourly
    return if schedule_expression.blank?

    schedule = Schedules::RecurringSchedule.from_expression(schedule_expression, timezone: schedule_timezone)
    schedule.validation_errors.each { |message| errors.add(:schedule_input, message) }
  rescue ArgumentError => e
    errors.add(:schedule_input, e.message)
  end

  def fire_at_is_in_the_future_at_create
    return if fire_at.blank?
    errors.add(:fire_at, "must be in the future") if fire_at <= Time.current
  end
end
