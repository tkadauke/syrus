# Append-only record of one worker cache lookup or pull outcome. Recording an
# outcome never grants or withholds worker capabilities.
class RuntimeImagePullEvent < ApplicationRecord
  include HasConfigurableRetention

  configurable_retention setting_key: :runtime_image_pull_event_retention_days, unit: :days

  OUTCOMES = %w[hit pulled registry_unavailable timeout corrupt revoked not_found failed busy].freeze

  belongs_to :runtime_image, optional: true

  validates :hostname, :digest, presence: true
  validates :outcome, inclusion: { in: OUTCOMES }

  scope :for_host, ->(hostname) { where(hostname: hostname) }
  scope :prunable, -> { (cutoff = retention_cutoff) ? where("created_at < ?", cutoff) : none }
  scope :since, ->(time) { where(created_at: time..) }

  def self.hit_ratio(scope = all)
    lookups = scope.where(prefetch: false, outcome: %w[hit pulled])
    total = lookups.count
    total.zero? ? nil : lookups.where(cache_hit: true).count.fdiv(total)
  end
end
