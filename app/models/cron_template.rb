class CronTemplate < ApplicationRecord
  PR_PILEUP_POLICIES = %w[ skip pile replace ].freeze

  belongs_to :user
  has_many :scheduled_tasks, dependent: :nullify

  # Transient, not persisted — see ScheduledTask#structured_intent.
  attr_accessor :structured_intent

  validates :name, presence: true, length: { maximum: 200 }
  validates :prompt, presence: true
  validates :schedule_expression, presence: true
  validates :pr_pileup_policy, presence: true, inclusion: { in: PR_PILEUP_POLICIES }
  validate  :schedule_expression_is_parseable_and_hourly

  before_validation :canonicalize_recurring_schedule

  scope :enabled_only, -> { where(enabled: true) }

  def hourly_cron_expression
    legacy_cron_expression.presence || cron_expression
  end

  def schedule_explanation
    Schedules::RecurringSchedule.explain(schedule_expression, timezone: schedule_timezone)
  rescue ArgumentError
    nil
  end

  def next_fire_at(from: Time.current)
    Schedules::RecurringSchedule.next_fire_at(schedule_expression, timezone: schedule_timezone, from: from)
  rescue ArgumentError
    nil
  end

  private

  def canonicalize_recurring_schedule
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
end
