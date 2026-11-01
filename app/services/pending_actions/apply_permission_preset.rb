module PendingActions
  class ApplyPermissionPreset < PermissionManagement
    action_key "apply_permission_preset"
    def execute = management.apply_preset!(payload, actor: user)
    def presentation_label = "Apply permission preset"
  end
end
