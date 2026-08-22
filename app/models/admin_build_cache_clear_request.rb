# A confirmable, audited request to clear (all, or a scoped subset of) the
# shared sccache compiler-cache bucket (EPIC-251). Mirrors this codebase's
# existing pending-action pattern (see ChatPendingAction) for destructive
# admin operations: create a pending record with a required audit reason,
# require a separate explicit confirm step to actually execute, and log the
# outcome to AdminAction. Deliberately not routed through ChatPendingAction
# itself — that model is chat_session-scoped, and this is a plain admin-UI
# surface with no chat involved.
class AdminBuildCacheClearRequest < ApplicationRecord
  SCOPES = %w[ full partial ].freeze
  STATES = %w[ pending confirmed cancelled ].freeze

  belongs_to :user

  enum :state, STATES.index_with(&:itself), validate: true

  before_validation :normalize_older_than_days

  validates :scope, inclusion: { in: SCOPES }
  validates :reason, presence: true
  validates :older_than_days, presence: true, numericality: { only_integer: true, greater_than: 0 }, if: :partial?
  validate :bucket_configured, on: :create
  validate :no_other_pending_request, on: :create

  def partial?
    scope == "partial"
  end

  # Executes the actual S3 deletion. Only legal from `pending` — this is the
  # one place the underlying bucket is actually mutated. `user:` is the admin
  # confirming the action (recorded on AdminAction even if it differs from
  # the original requester).
  def confirm!(user:)
    return false unless pending?
    return false unless Admin::BuildCache::Client.configured?

    outcome = execute_clear!

    update!(
      state: "confirmed",
      confirmed_at: Time.current,
      result: {
        "deleted_count" => outcome.deleted_count,
        "bytes_freed" => outcome.bytes_freed,
        "truncated" => outcome.truncated
      }
    )

    AdminAction.log!(
      user: user,
      action: :build_cache_clear,
      params: {
        request_id: id,
        requested_by_user_id: user_id,
        scope: scope,
        older_than_days: older_than_days,
        reason: reason,
        deleted_count: outcome.deleted_count,
        bytes_freed: outcome.bytes_freed,
        truncated: outcome.truncated
      }
    )

    true
  end

  def cancel!
    return false unless pending?

    update!(state: "cancelled", cancelled_at: Time.current)
  end

  private

  def execute_clear!
    client = Admin::BuildCache::Client.new
    partial? ? client.clear_older_than!(older_than_days) : client.clear_all!
  end

  def normalize_older_than_days
    self.older_than_days = nil unless partial?
  end

  def bucket_configured
    errors.add(:base, "build cache bucket is not configured") unless Admin::BuildCache::Client.configured?
  end

  def no_other_pending_request
    errors.add(:base, "another clear request is already pending") if AdminBuildCacheClearRequest.pending.exists?
  end
end
