# Shared payload for the repository "Members" tab: direct
# RepositoryMemberships plus additive TeamRepository grants. Both
# RepositoryMembershipsController and RepositoryTeamGrantsController
# return this same shape so either mutation can update the page's single
# query cache entry.
module RepositoryMembersSerialization
  extend ActiveSupport::Concern
  include RepositoryTabsSerialization

  private

  def repository_members_payload(repository, message: nil)
    {
      repository: {
        id: repository.id,
        slug: repository.slug,
        repository_path: repository_path(repository)
      },
      tabs: repository_tabs_json(repository),
      memberships: repository.repository_memberships.includes(:user).order(:id).map { |m| repository_membership_json(m) },
      team_grants: repository.team_repositories.includes(:team).order(:id).map { |g| repository_team_grant_json(g) },
      github_collaborator_discrepancies: repository.github_collaborator_discrepancies.order(:id).map { |d| github_collaborator_discrepancy_json(d) },
      message: message
    }
  end

  def repository_membership_json(membership)
    {
      id: membership.id,
      role: membership.role,
      agent_provider: membership.agent_provider,
      created_at: membership.created_at.iso8601,
      github_permission_mismatch_reason: membership.github_permission_mismatch_reason,
      github_permission_mismatch_checked_at: membership.github_permission_mismatch_checked_at&.iso8601,
      user: {
        id: membership.user.id,
        email_address: membership.user.email_address,
        name: membership.user.display_name
      }
    }
  end

  def github_collaborator_discrepancy_json(discrepancy)
    {
      id: discrepancy.id,
      github_login: discrepancy.github_login,
      github_permission: discrepancy.github_permission,
      checked_at: discrepancy.checked_at.iso8601
    }
  end

  def repository_team_grant_json(grant)
    {
      id: grant.id,
      role: grant.role,
      created_at: grant.created_at.iso8601,
      team: {
        id: grant.team.id,
        name: grant.team.name
      }
    }
  end
end
