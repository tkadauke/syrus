class SystemAlertNotification < ApplicationRecord
  validates :dismissal_key, presence: true, uniqueness: true
  validates :alert_id, :severity, :title, presence: true
  validates :delivery_attempts, numericality: { greater_than_or_equal_to: 0 }

  scope :undelivered, -> { where(delivered_at: nil) }
  scope :dead_lettered, -> { undelivered.where.not(dead_lettered_at: nil) }
  scope :retrying, -> { undelivered.where(dead_lettered_at: nil).where("delivery_attempts > 0") }

  def delivered?
    delivered_at.present?
  end

  def dead_lettered?
    dead_lettered_at.present?
  end

  def retry_due?(now = Time.current)
    !delivered? && !dead_lettered? && (next_attempt_at.blank? || next_attempt_at <= now)
  end
end
