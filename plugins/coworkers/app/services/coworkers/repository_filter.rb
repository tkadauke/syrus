class Coworkers::RepositoryFilter
  include Syrus::Host::RepositoryFilter

  def self.apply(scope:, user:)
    workspace_slugs = Coworkers::Coworker.where(owner_user: user).pluck(:workspace_repo).filter_map do |remote|
      match = remote.match(%r{github\.com[:/]([^/]+)/([^/]+?)(?:\.git)?\z}i)
      [ match[1].downcase, match[2].downcase ] if match
    end
    return scope if workspace_slugs.empty?

    repositories = Syrus::Host::Repositories.arel_table
    workspace_predicate = workspace_slugs.uniq.map do |owner, name|
      repositories[:owner].lower.eq(owner).and(repositories[:name].lower.eq(name))
    end.reduce(&:or)
    dedicated_ids = Coworkers::WorkspaceRepository.select(:repository_id)
    workspace_only_ids = Syrus::Host::Repositories.where(id: dedicated_ids).where(workspace_predicate).select(:id)

    scope.where.not(id: workspace_only_ids)
  end
end
