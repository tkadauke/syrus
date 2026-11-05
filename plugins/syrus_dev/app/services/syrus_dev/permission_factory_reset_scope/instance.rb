module SyrusDev
  class PermissionFactoryResetScope::Instance < PermissionFactoryResetScope
    def users = ::User.all
    def profile_users = users
    def rules = PermissionRule.all
    def leases = PermissionLease.all
    def requests = ChatPendingAction.where(request_kind: "authorization_request")

    private

    def validate!
      raise ArgumentError, "instance scope does not accept an id" if id.present?
    end
  end
end
