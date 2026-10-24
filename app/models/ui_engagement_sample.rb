class UiEngagementSample < ApplicationRecord
  MAX_DURATION_MS = 24.hours.in_milliseconds
  RETENTION_WINDOW = 90.days
  ROUTE_PARAM_KEYS = {
    "job.show" => %w[job_id],
    "job.review" => %w[job_id],
    "chat.show" => %w[chat_id]
  }.freeze

  belongs_to :user

  validates :route_id, inclusion: { in: ROUTE_PARAM_KEYS.keys }
  validates :active_ms, :visible_ms, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: MAX_DURATION_MS }
  validates :started_at, :ended_at, presence: true
  validate :valid_time_range
  validate :valid_route_params
  validate :active_time_is_visible_time

  scope :prunable, -> { where("ended_at < ?", RETENTION_WINDOW.ago) }

  private

  def valid_time_range
    return if started_at.blank? || ended_at.blank?

    errors.add(:ended_at, "must be after started_at") if ended_at < started_at
    errors.add(:ended_at, "is too far after started_at") if ended_at - started_at > MAX_DURATION_MS / 1000
  end

  def valid_route_params
    expected_keys = ROUTE_PARAM_KEYS[route_id]
    return unless expected_keys

    normalized = route_params.to_h.stringify_keys
    errors.add(:route_params, "must contain only #{expected_keys.join(', ')}") unless normalized.keys.sort == expected_keys.sort
    errors.add(:route_params, "values must be positive integer IDs") unless normalized.values.all? { |value| value.to_s.match?(/\A[1-9]\d*\z/) }
  end

  def active_time_is_visible_time
    errors.add(:active_ms, "cannot exceed visible_ms") if active_ms && visible_ms && active_ms > visible_ms
  end
end
