class Coworkers::ProvisioningAttempt < ApplicationRecord
  self.table_name = "coworker_provisioning_attempts"

  STATES = %w[provisioning completed cleanup_pending cleaned manual_attention].freeze

  belongs_to :owner_user, class_name: "User"
  belongs_to :coworker, class_name: "Coworkers::Coworker", optional: true
  belongs_to :acknowledged_by, class_name: "User", optional: true

  validates :idempotency_key, :remote_owner, :remote_name, :handle, :branch, presence: true
  validates :idempotency_key, uniqueness: { scope: :owner_user_id }
  validates :state, inclusion: { in: STATES }
  validates :branch, format: { with: %r{\Acoworkers/[a-z0-9_-]+\z} }

  scope :requiring_reconciliation, ->(cutoff:) {
    where(state: "cleanup_pending").or(where(state: "provisioning", updated_at: ...cutoff))
  }

  def public_status
    attributes.slice("id", "handle", "branch", "state", "retry_count", "last_error", "updated_at",
      "completed_at", "cleaned_at", "manual_attention_at", "acknowledged_at")
  end
end
