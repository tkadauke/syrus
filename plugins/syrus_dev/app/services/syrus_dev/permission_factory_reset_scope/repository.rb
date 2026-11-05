module SyrusDev
  class PermissionFactoryResetScope::Repository < PermissionFactoryResetScope
    def repository = @repository ||= ::Repository.find(id)

    def users
      ::User.where(id: rules.select(:owner_user_id))
        .or(::User.where(id: leases.select(:owner_user_id)))
        .or(::User.where(id: requests.select(:user_id)))
    end

    def rules = PermissionRule.where(subject_repository_id: repository.id)
    def leases = PermissionLease.where(subject_repository_id: repository.id)
    def requests = ChatPendingAction.where(request_kind: "authorization_request", repository_id: repository.id)
  end
end
