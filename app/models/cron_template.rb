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

  scope :enabled_only, -> { where(enabled: true) }

  private

  def cron_expression_is_parseable_and_hourly
    return if cron_expression.blank?
    cron = Fugit.parse(cron_expression)
    if cron.nil? || !cron.is_a?(Fugit::Cron)
      errors.add(:cron_expression, "is not a valid cron expression")
      return
    end
    hourly_cron = Fugit.parse(hourly_cron_expression)
    if hourly_cron.nil? || !hourly_cron.is_a?(Fugit::Cron) || next_cron_time(hourly_cron).nil?
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
