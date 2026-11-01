module PendingActions
  class RevokePermission < PermissionManagement
    action_key "revoke_permission"
    def execute = management.revoke_rule!(payload.fetch("permission_rule_id"), actor: user)
    def presentation_label = "Revoke permission"
  end
end
