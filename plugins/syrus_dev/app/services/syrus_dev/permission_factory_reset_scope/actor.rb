module SyrusDev
  class PermissionFactoryResetScope::Actor < PermissionFactoryResetScope
    def actor = @actor ||= GlobalID::Locator.locate(id) || raise(ActiveRecord::RecordNotFound)
    def users = Syrus::Host::UserRecord.where(id: actor.respond_to?(:user_id) ? actor.user_id : actor.id)

    def rules
      Syrus::Host::PermissionRule.where(subject_selector_type: "agent", subject_selector_id: actor.id.to_s)
    end

    def leases
      Syrus::Host::PermissionLease.where(subject_selector_type: "agent", subject_selector_id: actor.id.to_s)
    end

    def requests = ChatPendingAction.where(request_kind: "authorization_request", subject: actor)
  end
end
