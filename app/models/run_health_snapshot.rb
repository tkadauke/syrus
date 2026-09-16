class RunHealthSnapshot < ApplicationRecord
  include HasConfigurableRetention

  belongs_to :run

  HEALTH_STATUSES = %w[ healthy warning critical ].freeze

  # Snapshots are operational — no need for 30-day forensic retention.
  # Seven days covers any incident triage window an operator would need.
  configurable_retention setting_key: :run_health_snapshot_retention_days, unit: :days

  scope :ordered, -> { order(:created_at) }
  scope :prunable, -> {
    cutoff = retention_cutoff
    cutoff ? where("created_at < ?", cutoff) : none
  }
end
