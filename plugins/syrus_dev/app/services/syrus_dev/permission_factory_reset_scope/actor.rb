module SyrusDev
  class PermissionFactoryResetScope::Actor < PermissionFactoryResetScope
    def actor = @actor ||= GlobalID::Locator.locate(id) || raise(ActiveRecord::RecordNotFound)
    def users = ::User.where(id: actor.respond_to?(:user_id) ? actor.user_id : actor.id)

    def rules
      PermissionRule.where(subject_selector_type: "agent", subject_selector_id: actor.id.to_s)
    end

    def leases
      PermissionLease.where(subject_selector_type: "agent", subject_selector_id: actor.id.to_s)
    end

    def requests = ChatPendingAction.where(request_kind: "authorization_request", subject: actor)
  end
end
