module SyrusDev
  class PermissionFactoryResetScope::Instance < PermissionFactoryResetScope
    def users = Syrus::Host::UserRecord.all
    def profile_users = users
    def rules = Syrus::Host::PermissionRule.all
    def leases = Syrus::Host::PermissionLease.all
    def requests = Syrus::Host::ChatPendingActionRecord.where(request_kind: "authorization_request")

    private

    def validate!
      raise ArgumentError, "instance scope does not accept an id" if id.present?
    end
  end
end
