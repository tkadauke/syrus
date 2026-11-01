module PendingActions
  class GrantPermission < PermissionManagement
    action_key "grant_permission"
    def execute = management.grant!(payload, actor: user)
    def presentation_label = "Grant permission"
  end
end
