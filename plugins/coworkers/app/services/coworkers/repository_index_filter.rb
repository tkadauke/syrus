class Coworkers::RepositoryIndexFilter
  include Syrus::Plugin::RepositoryIndexFilter

  def self.apply(scope:, user:)
    workspace_slugs = Coworkers::Coworker.where(owner_user: user).pluck(:workspace_repo).filter_map do |remote|
      match = remote.match(%r{github\.com[:/]([^/]+)/([^/]+?)(?:\.git)?\z}i)
      [ match[1].downcase, match[2].downcase ] if match
    end
    return scope if workspace_slugs.empty?

    repositories = Repository.arel_table
    workspace_predicate = workspace_slugs.uniq.map do |owner, name|
      repositories[:owner].lower.eq(owner).and(repositories[:name].lower.eq(name))
    end.reduce(&:or)
    dedicated_ids = Coworkers::WorkspaceRepository.select(:repository_id)
    workspace_only_ids = Repository.where(id: dedicated_ids).where(workspace_predicate).select(:id)

    scope.where.not(id: workspace_only_ids)
  end
end
