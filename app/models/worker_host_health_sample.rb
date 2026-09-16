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

  private

  def default_raw_metrics
    self.raw_metrics ||= {}
  end
end
