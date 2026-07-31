class WorkerHostHealthSample < ApplicationRecord
  RETAIN_AFTER = 7.days

  before_validation :default_raw_metrics

  validates :hostname, :role, :version, :observed_at, presence: true

  scope :ordered, -> { order(:observed_at) }
  scope :recent, -> { order(observed_at: :desc) }
  scope :prunable, -> { where("observed_at < ?", RETAIN_AFTER.ago) }

  private

  def default_raw_metrics
    self.raw_metrics ||= {}
  end
end
