module PendingActions
  class RevokePermissionLease < PermissionManagement
    action_key "revoke_permission_lease"
    def execute = management.revoke_lease!(payload.fetch("permission_lease_id"), actor: user)
    def presentation_label = "Revoke permission lease"
  end
end
