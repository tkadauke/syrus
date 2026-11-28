# Append-only record of a lifecycle or integrity decision the Runtime Image
# Service made (publish, revoke, retain, delete, garbage collection,
# reconciliation repair, authentication failure). Pull outcomes live in
# RuntimeImagePullEvent; this table is for operator-relevant decisions.
class RuntimeImageAuditEvent < ApplicationRecord
  include HasConfigurableRetention

  configurable_retention setting_key: :runtime_image_audit_event_retention_days, unit: :days

  OUTCOMES = %w[ok failed skipped repaired detected].freeze

  belongs_to :runtime_image, optional: true
  belongs_to :runtime_image_namespace, optional: true

  attribute :details, :json, default: -> { {} }
  before_validation { self.details ||= {} }
  before_validation { self.occurred_at ||= Time.current }
  before_update { raise ActiveRecord::ReadOnlyRecord, "runtime image audit evidence is immutable" }

  validates :event_type, presence: true
  validates :outcome, inclusion: { in: OUTCOMES }

  scope :prunable, -> { (cutoff = retention_cutoff) ? where("occurred_at < ?", cutoff) : none }
  scope :recent_first, -> { order(occurred_at: :desc, id: :desc) }
  scope :since, ->(time) { where(occurred_at: time..) }
end
