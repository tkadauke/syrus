require "fugit"

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

  validates :cron_expression, presence: true, if: :cron?
  validates :fire_at,         presence: true, if: :one_shot?
  validate  :cron_expression_is_parseable_and_hourly, if: :cron?
  validate  :cron_dom_and_month_are_valid,             if: :cron?
  validate  :fire_at_is_in_the_future_at_create,      if: -> { one_shot? && new_record? }

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

  # Cron expression used for scheduling. Kept under the historical
  # hourly_cron_expression name for API compatibility.
  def hourly_cron_expression
    return nil unless cron? && cron_expression.present?
    cron_expression
  end

  def display_cron_expression
    cron? ? cron_expression : nil
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

      cron = parsed_hourly_cron
      cron && cron.next_time(from).to_t
    end
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
    cron = parsed_hourly_cron
    return nil unless cron

    window_start = now.utc.change(min: 0, sec: 0, usec: 0)
    scheduled_tick = cron.next_time(window_start - 1.second).to_t
    return nil unless scheduled_tick >= window_start && scheduled_tick < window_start + 1.hour
    return nil if scheduled_tick > now

    window_start
  end

  # Always interpret cron expressions in UTC. v1 is UTC-only by design;
  # without an explicit zone Fugit uses the host's local TZ, which makes
  # behavior depend on where the worker happens to run. Force the zone
  # by appending "UTC" before parsing.
  def parsed_hourly_cron
    expr = hourly_cron_expression
    return nil if expr.blank?
    Fugit.parse("#{expr} UTC")
  end

  def seed_minute_offset_for_cron
    return unless cron?
    return if minute_offset_changed? && !minute_offset.nil?

    self.minute_offset = SecureRandom.random_number(60)
  end

  # Fugit accepts a wide range of cron syntaxes; we narrow to "fires at
  # most once per hour" after normalizing the ignored minute slot. This
  # lets users paste ordinary five-field cron while making the hourly
  # window semantics explicit.
  def cron_expression_is_parseable_and_hourly
    cron = Fugit.parse(cron_expression)
    if cron.nil? || !cron.is_a?(Fugit::Cron)
      return if cron_dom_or_month_contains_invalid_position_value?

      errors.add(:cron_expression, "is not a valid cron expression")
      return
    end

    hourly_cron = Fugit.parse(hourly_cron_expression)
    if hourly_cron.nil? || !hourly_cron.is_a?(Fugit::Cron) || next_cron_time(hourly_cron).nil?
      return if cron_dom_or_month_contains_invalid_position_value?

      errors.add(:cron_expression, "does not produce a future scheduled time")
      return
    end

    min_gap = min_consecutive_gap(hourly_cron)
    if min_gap < MIN_CRON_INTERVAL.to_i
      errors.add(:cron_expression, "must fire at most once per hour (smallest interval seen: #{min_gap / 60} minutes)")
    end
  rescue ArgumentError => e
    errors.add(:cron_expression, "is not parseable: #{e.message}")
  end

  def cron_dom_and_month_are_valid
    return if cron_expression.blank?

    fields = cron_expression.to_s.split(/\s+/)
    return unless fields.length == 5

    if cron_position_values(fields[2]).any? { |value| value < 1 }
      errors.add(:cron_expression, "has an invalid day-of-month value (0 is not allowed; use 1–31 or *)")
    end

    if cron_position_values(fields[3]).any? { |value| value < 1 }
      errors.add(:cron_expression, "has an invalid month value (0 is not allowed; use 1–12 or *)")
    end
  end

  def cron_dom_or_month_contains_invalid_position_value?
    fields = cron_expression.to_s.split(/\s+/)
    return false unless fields.length == 5

    [ fields[2], fields[3] ].any? do |field|
      cron_position_values(field).any? { |value| value < 1 }
    end
  end

  def cron_position_values(field)
    field.to_s.split(",").flat_map do |element|
      value = element.strip.split("/", 2).first
      next [] if value.blank? || value == "*"

      value.split("-", 2).filter_map { |part| Integer(part, exception: false) }
    end
  end

  def min_consecutive_gap(cron, samples: 60, from: Time.utc(2026, 1, 1, 0, 0, 0))
    times = []
    cursor = from
    samples.times do
      cursor = next_cron_time(cron, from: cursor)
      return 0 if cursor.nil?

      times << cursor
    end
    times.each_cons(2).map { |a, b| (b - a).to_i }.min
  end

  def next_cron_time(cron, from: Time.utc(2026, 1, 1, 0, 0, 0))
    cron.next_time(from)&.to_t
  end

  def fire_at_is_in_the_future_at_create
    return if fire_at.blank?
    errors.add(:fire_at, "must be in the future") if fire_at <= Time.current
  end
end
