module PendingActions
  class CreatePermissionLease < PermissionManagement
    action_key "create_permission_lease"
    def execute = management.lease!(payload, actor: user)
    def presentation_label = "Create temporary permission lease"
  end
end
