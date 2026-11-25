module SyrusDev
  class PermissionFactoryResetScope::User < PermissionFactoryResetScope
    def user = @user ||= Syrus::Host::UserRecord.find(id)
    def users = Syrus::Host::UserRecord.where(id: user.id)
    def profile_users = users
    def rules = Syrus::Host::PermissionRule.where(owner_user_id: user.id)
    def leases = Syrus::Host::PermissionLease.where(owner_user_id: user.id)
    def requests = Syrus::Host::ChatPendingActionRecord.where(request_kind: "authorization_request", user_id: user.id)
  end
end
