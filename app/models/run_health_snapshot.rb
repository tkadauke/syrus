class RunHealthSnapshot < ApplicationRecord
  belongs_to :run

  HEALTH_STATUSES = %w[ healthy warning critical ].freeze

  # Snapshots are operational — no need for 30-day forensic retention.
  # Seven days covers any incident triage window an operator would need.
  RETAIN_AFTER = 7.days

  scope :ordered, -> { order(:created_at) }
  scope :prunable, -> { where("created_at < ?", RETAIN_AFTER.ago) }

  # Turbo Stream: when a snapshot is created, morph the watching job page
  # so the operator sees the result without refreshing.
  broadcasts_refreshes_to ->(snapshot) {
    run = snapshot.run
    run&.job || [ "dead_snapshot", snapshot.id ]
  }
end
