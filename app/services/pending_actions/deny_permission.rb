module PendingActions
  class DenyPermission < PermissionManagement
    action_key "deny_permission"
    def execute = management.deny!(payload, actor: user)
    def presentation_label = "Deny permission"
  end
end
