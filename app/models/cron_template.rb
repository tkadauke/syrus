require "fugit"

class CronTemplate < ApplicationRecord
  PR_PILEUP_POLICIES = %w[ skip pile replace ].freeze
  MIN_CRON_INTERVAL = 1.hour

  belongs_to :user
  has_many :scheduled_tasks, dependent: :nullify

  validates :name, presence: true, length: { maximum: 200 }
  validates :prompt, presence: true
  validates :cron_expression, presence: true
  validates :pr_pileup_policy, presence: true, inclusion: { in: PR_PILEUP_POLICIES }
  validate  :cron_expression_is_parseable_and_hourly
  validate  :cron_dom_and_month_are_valid

  scope :enabled_only, -> { where(enabled: true) }

  private

  def cron_expression_is_parseable_and_hourly
    return if cron_expression.blank?
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

  def hourly_cron_expression
    cron_expression
  end
end
