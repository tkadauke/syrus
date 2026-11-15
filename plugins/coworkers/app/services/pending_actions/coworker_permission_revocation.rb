module PendingActions
  # Owner-confirmed revocation of a durable rule that applies to the requesting
  # coworker. The coworker only asks; the confirming owner revokes, and the
  # rule is re-resolved against the owner's store and the exact coworker subject
  # at confirmation time.
  class CoworkerPermissionRevocation < PermissionManagement
    action_key "coworker_permission_revocation"
    requires_chat_session!

    def execute
      coworker = action.subject
      raise ArgumentError, "requesting coworker is no longer available" unless coworker

      rule = management.rules(active: false).find(payload.fetch("permission_rule_id"))
      unless Permissions::CoworkerPermissionRevocationRequest.targets?(rule, coworker)
        raise ArgumentError, "permission rule does not apply to the requesting coworker"
      end

      rule.revoke!(actor: user)
      Permissions::CoworkerAudit.record!(:coworker_permission_revoked, owner: user, coworker:,
        permission_rule_id: rule.id, capability: rule.capability, operation: rule.operation)
      rule
    end

    def presentation_label = "Revoke permission for coworker"
    def presentation_detail = [ payload["capability"], payload["operation"], payload["rationale"] ].compact.join(" · ")
  end
end
