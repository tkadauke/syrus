class WorkerHostHealthSample < ApplicationRecord
  include HasConfigurableRetention

  configurable_retention setting_key: :worker_host_health_sample_retention_days, unit: :days

  before_validation :default_raw_metrics

  validates :hostname, :role, :version, :observed_at, presence: true

  scope :ordered, -> { order(:observed_at) }
  scope :recent, -> { order(observed_at: :desc) }
  scope :worker_role, -> { where(role: "worker") }
  scope :prunable, -> {
    cutoff = retention_cutoff
    cutoff ? where("observed_at < ?", cutoff) : none
  }

  # Samples older than the retention window are guaranteed gone, so callers
  # correlating other data (Runs, command spans) against sample history clamp
  # to this floor instead of querying earlier than what could possibly exist.
  # Infinite retention (window nil) means no clamp is needed.
  def self.retention_floor(now: Time.current)
    window = retention_window
    window ? now - window : Time.at(0)
  end

  private

  def default_raw_metrics
    self.raw_metrics ||= {}
  end
end
