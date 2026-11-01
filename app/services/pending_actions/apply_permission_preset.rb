module PendingActions
  class ApplyPermissionPreset < PermissionManagement
    action_key "apply_permission_preset"
    def execute
      management.apply_preset!(payload, actor: user)
      nil # A preset may create several rules; the pending action has one result slot.
    end
    def presentation_label = "Apply permission preset"

    def presentation_detail
      management.preset_drafts(payload).map do |draft|
        "#{draft.fetch('policy').upcase} #{draft.fetch('operation')} for #{draft.fetch('role')} (#{draft.fetch('subject_selector_type')})"
      end.join("\n")
    end
  end
end
