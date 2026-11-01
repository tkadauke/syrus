class PermissionRuleAuditEvent < ApplicationRecord
  EVENT_TYPES = %w[ created updated revoked ].freeze

  belongs_to :permission_rule, inverse_of: :audit_events
  belongs_to :actor_user, class_name: "User"

  validates :sequence, numericality: { only_integer: true, greater_than: 0 }, uniqueness: { scope: :permission_rule_id }
  validates :event_type, inclusion: { in: EVENT_TYPES }
  validates :snapshot, :changed_fields, presence: true

  before_update { raise ActiveRecord::ReadOnlyRecord, "PermissionRuleAuditEvent is append-only" }
  before_destroy { raise ActiveRecord::ReadOnlyRecord, "PermissionRuleAuditEvent is append-only" }
end
