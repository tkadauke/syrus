module PendingActions
  class CancelAuthorizationRequest < PermissionManagement
    action_key "cancel_authorization_request"

    def execute
      target = ChatPendingAction.where(user: user, request_kind: "authorization_request").find(payload.fetch("authorization_request_id"))
      raise ArgumentError, "authorization request is no longer cancellable" unless target.cancel!(user: user)

      target
    end

    def presentation_label = "Cancel authorization request"
  end
end
