module Permissions
  # A coworker voluntarily giving up its own temporary authority. Only an active
  # lease whose subject is exactly the calling coworker qualifies; anything else
  # is reported as not found so a coworker cannot probe other subjects' leases.
  class CoworkerLeaseSurrender
    def initialize(context:)
      @context = context
    end

    def call(lease_id)
      coworker = context.agent_actor
      unless context.role.in?([ AgentRole::COWORKER_CHAT, AgentRole::COWORKER ]) && coworker &&
          coworker.owner_user_id == context.user.id
        raise CoworkerPermissionRequest::Rejected.new(:not_a_coworker, "only a coworker can surrender its own lease")
      end

      lease = PermissionLease.where(owner_user: context.user, subject_selector_type: "agent",
        subject_selector_id: coworker.id.to_s).not_revoked.not_expired.find_by(id: lease_id)
      raise CoworkerPermissionRequest::Rejected.new(:lease_not_found, "no active lease of yours has that id") unless lease

      lease.revoke!(actor: context.user)
      CoworkerAudit.record!(:coworker_permission_lease_surrendered, owner: context.user, coworker:,
        permission_lease_id: lease.id, capability: lease.capability, operation: lease.operation,
        duration: lease.duration_kind)
      lease
    end

    private

    attr_reader :context
  end
end
