module Permissions
  # Append-only audit trail for the coworker-facing permission workflows
  # (requests, decisions, surrender and revocation requests). Rule creation and
  # revocation additionally keep their own PermissionRuleAuditEvent rows; this
  # trail records who asked, who decided and what the coworker did on its own.
  module CoworkerAudit
    EVENTS = %w[
      coworker_permission_requested
      coworker_permission_request_deduplicated
      coworker_permission_request_rate_limited
      coworker_permission_request_denied
      coworker_permission_granted
      coworker_permission_lease_surrendered
      coworker_permission_revocation_requested
      coworker_permission_revoked
    ].freeze

    def self.record!(event, owner:, coworker:, **details)
      raise ArgumentError, "unknown coworker permission audit event" unless EVENTS.include?(event.to_s)

      AdminAction.log!(
        user: owner, action: event,
        params: { "coworker_id" => coworker.id, "coworker_handle" => coworker.try(:handle) }.merge(details.compact.deep_stringify_keys)
      )
    end

    def self.events_for(coworker)
      AdminAction.where(action: EVENTS).order(:id).select do |action|
        action.params.is_a?(Hash) && action.params["coworker_id"] == coworker.id
      end
    end
  end
end
