module PendingActions
  # The durable authorization request a coworker raises for authority for
  # itself. It is decided only through Permissions::CoworkerAuthorizationDecision
  # (adaptive rule/lease approval or denial); it has no invocation to execute,
  # so confirming it through the generic action path is always refused.
  class CoworkerPermissionRequest < Base
    action_key "coworker_permission_request"
    requires_chat_session!

    def execute
      raise ArgumentError, "coworker permission requests are decided through the authorization decision flow"
    end

    def presentation_label = "Approve coworker permission request"
    def presentation_detail = action.purpose.to_s.truncate(120)
  end
end
