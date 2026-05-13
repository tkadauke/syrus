require "fugit"

class RecurringTask < ApplicationRecord
  belongs_to :repository
  belongs_to :user

  validates :cron_expression, presence: true
  validates :label, presence: true, length: { maximum: 200 }
  validates :prompt, presence: true
  validates :next_fire_at, presence: true
  validate :cron_expression_is_parseable

  before_validation :assign_next_fire_at, on: :create

  scope :enabled, -> { where(enabled: true) }
  scope :due, ->(now = Time.current) { enabled.where("next_fire_at <= ?", now) }

  def next_fire_after(from:)
    parsed_cron&.next_time(from)&.to_t
  end

  def advance!(from: Time.current)
    update!(next_fire_at: next_fire_after(from: from))
  end

  private

  def assign_next_fire_at
    return if next_fire_at.present?

    self.next_fire_at = next_fire_after(from: Time.current)
  end

  def parsed_cron
    return nil if cron_expression.blank?

    Fugit.parse("#{cron_expression} UTC")
  end

  def cron_expression_is_parseable
    cron = parsed_cron
    errors.add(:cron_expression, "is not a valid cron expression") unless cron.is_a?(Fugit::Cron)
  rescue ArgumentError => e
    errors.add(:cron_expression, "is not parseable: #{e.message}")
  end
end
