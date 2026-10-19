module Mcp::Tools
  module ProviderRoutingToolSupport
    include AuthorizationSupport

    private

    def provider_routing_rule_set!(scope_type:, repository_id: nil, job_id: nil)
      scope = provider_routing_scope!(scope_type: scope_type, repository_id: repository_id, job_id: job_id)
      ProviderRouting::RuleSet.new(**scope)
    end

    def provider_routing_scope!(scope_type:, repository_id: nil, job_id: nil)
      case scope_type.to_s
      when "user"
        { scope_type: "user", scope_id: current_user.id, user_id: current_user.id }
      when "repository"
        repository = provider_routing_repository!(repository_id)
        authorize_provider_routing_repository!(repository)
        { scope_type: "repository", scope_id: repository.id, repository_id: repository.id, user_id: repository.user_id || current_user.id }
      when "job"
        job = find_job!(Integer(job_id), includes: :repository)
        raise AuthorizationSupport::AuthorizationError unless JobPolicy.new(current_user, job).write?

        { scope_type: "job", scope_id: job.id, job_id: job.id, repository_id: job.repository_id, user_id: job.effective_owner_id }
      else
        raise ProviderRouting::RuleSet::InvalidOperation, "scope_type must be user, repository, or job"
      end
    rescue ArgumentError, TypeError
      raise ProviderRouting::RuleSet::InvalidOperation, "the selected scope requires a valid id"
    end

    def provider_routing_repository!(repository_id)
      id = Integer(repository_id)
      scope = current_user.admin? ? Repository.active : Repository.accessible_to(current_user).active
      scope.find(id)
    rescue ActiveRecord::RecordNotFound
      raise AuthorizationSupport::AuthorizationError, "repository not found or not accessible"
    end

    def authorize_provider_routing_repository!(repository)
      raise AuthorizationSupport::AuthorizationError unless RepositoryPolicy.new(current_user, repository).update?
    end
  end
end
