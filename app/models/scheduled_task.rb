require "fugit"

class ScheduledTask < ApplicationRecord
  include AutoApproveModes

  KINDS = %w[ cron one_shot ].freeze
  STATES = %w[ scheduled paused auto_paused fired ].freeze
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

  # Cron expression with the minute slot rewritten to the task's stored
  # offset, so that two tasks created with the same nominal cron don't
  # collide on the same minute. Fugit does the parsing, we splice the
  # offset into the standard 5-field minute slot.
  def smeared_cron_expression
    return nil unless cron? && cron_expression.present?
    fields = cron_expression.split(/\s+/, 5)
    return cron_expression if fields.size < 5
    [ minute_offset.to_s, *fields[1..] ].join(" ")
  end

  # When does this task fire next, after `from`? Returns nil if it
  # won't (paused, archived, fired one_shot, malformed cron). For
  # cron tasks the smeared expression is what's evaluated.
  def next_fire_at(from: Time.current)
    return nil unless active?

    if one_shot?
      fire_at && fire_at > from ? fire_at : nil
    else
      cron = parsed_smeared_cron
      cron && cron.next_time(from).to_t
    end
  end

  # Has the next scheduled fire time arrived? Uses last_fired_at as the
  # baseline reference (so we don't double-fire within a single window),
  # falling back to created_at the first time around.
  def due?(now: Time.current)
    return false unless active?

    if one_shot?
      fire_at.present? && fire_at <= now
    else
      cron = parsed_smeared_cron
      return false unless cron
      reference = last_fired_at || created_at
      next_after_reference = cron.next_time(reference).to_t
      next_after_reference.present? && next_after_reference <= now
    end
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
    case reason
    when "operator"   then update!(state: "paused")
    when "auto"       then update!(state: "auto_paused")
    end
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

  # Always interpret cron expressions in UTC. v1 is UTC-only by design;
  # without an explicit zone Fugit uses the host's local TZ, which makes
  # behavior depend on where the worker happens to run. Force the zone
  # by appending "UTC" before parsing.
  def parsed_smeared_cron
    expr = smeared_cron_expression
    return nil if expr.blank?
    Fugit.parse("#{expr} UTC")
  end

  def seed_minute_offset_for_cron
    return unless cron?
    return if minute_offset_changed? && minute_offset != 0
    self.minute_offset = SecureRandom.random_number(60)
  end

  # Fugit accepts a wide range of cron syntaxes; we narrow to "fires at
  # most once per hour" so the smear-by-minute-offset trick still spaces
  # tasks out, and so we don't accidentally enqueue 60 Jobs in an hour
  # from a `* * * * *` pasted in a hurry. Fugit 1.x doesn't expose a
  # ready-made #frequency, so we sample 60 consecutive fires and check
  # the smallest gap — robust enough for any human-readable cron (the
  # "min interval" period for sane crons cycles within an hour).
  def cron_expression_is_parseable_and_hourly
    cron = Fugit.parse(cron_expression)
    if cron.nil? || !cron.is_a?(Fugit::Cron)
      errors.add(:cron_expression, "is not a valid cron expression")
      return
    end

    min_gap = min_consecutive_gap(cron)
    if min_gap < MIN_CRON_INTERVAL.to_i
      errors.add(:cron_expression, "must fire at most once per hour (smallest interval seen: #{min_gap / 60} minutes)")
    end
  rescue ArgumentError => e
    errors.add(:cron_expression, "is not parseable: #{e.message}")
  end

  def min_consecutive_gap(cron, samples: 60, from: Time.utc(2026, 1, 1, 0, 0, 0))
    times = []
    cursor = from
    samples.times do
      cursor = cron.next_time(cursor).to_t
      times << cursor
    end
    times.each_cons(2).map { |a, b| (b - a).to_i }.min
  end

  def fire_at_is_in_the_future_at_create
    return if fire_at.blank?
    errors.add(:fire_at, "must be in the future") if fire_at <= Time.current
  end
end
