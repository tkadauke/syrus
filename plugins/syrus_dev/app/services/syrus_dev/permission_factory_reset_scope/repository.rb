module SyrusDev
  class PermissionFactoryResetScope::Repository < PermissionFactoryResetScope
    def repository = @repository ||= Syrus::Host::RepositoryRecord.find(id)

    def users
      Syrus::Host::UserRecord.where(id: rules.select(:owner_user_id))
        .or(Syrus::Host::UserRecord.where(id: leases.select(:owner_user_id)))
        .or(Syrus::Host::UserRecord.where(id: requests.select(:user_id)))
    end

    def rules = Syrus::Host::PermissionRule.where(subject_repository_id: repository.id)
    def leases = Syrus::Host::PermissionLease.where(subject_repository_id: repository.id)
    def requests = Syrus::Host::ChatPendingActionRecord.where(request_kind: "authorization_request", repository_id: repository.id)
  end
end
