module SyrusDev
  class PermissionFactoryResetScope::User < PermissionFactoryResetScope
    def user = @user ||= ::User.find(id)
    def users = ::User.where(id: user.id)
    def profile_users = users
    def rules = PermissionRule.where(owner_user_id: user.id)
    def leases = PermissionLease.where(owner_user_id: user.id)
    def requests = ChatPendingAction.where(request_kind: "authorization_request", user_id: user.id)
  end
end
