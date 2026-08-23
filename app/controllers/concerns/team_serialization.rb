module TeamSerialization
  extend ActiveSupport::Concern

  private

  def teams_payload(message: nil)
    teams = policy_scope(Team).order(:name)
    {
      teams: teams.map { |team| team_json(team) },
      message: message
    }
  end

  def team_detail_payload(team, message: nil)
    {
      team: team_json(team),
      can_manage: TeamPolicy.new(Current.user, team).write?,
      memberships: team.team_memberships.includes(:user).order(:id).map { |m| team_membership_json(m) },
      repository_grants: team.team_repositories.includes(:repository).order(:id).map { |g| team_repository_grant_json(g) },
      message: message
    }
  end

  def team_json(team)
    {
      id: team.id,
      name: team.name,
      member_count: team.team_memberships.size,
      repository_count: team.team_repositories.size,
      owned_by_current_user: team.owned_by?(Current.user),
      team_path: "/admin/teams/#{team.id}"
    }
  end

  def team_membership_json(membership)
    {
      id: membership.id,
      role: membership.role,
      created_at: membership.created_at.iso8601,
      user: {
        id: membership.user.id,
        email_address: membership.user.email_address,
        name: membership.user.display_name
      }
    }
  end

  def team_repository_grant_json(grant)
    {
      id: grant.id,
      role: grant.role,
      created_at: grant.created_at.iso8601,
      repository: {
        id: grant.repository.id,
        slug: grant.repository.slug
      }
    }
  end
end
