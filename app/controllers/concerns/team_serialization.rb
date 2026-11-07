module TeamSerialization
  extend ActiveSupport::Concern

  private

  def teams_payload(message: nil)
    teams = policy_scope(Team).order(:name).to_a
    preload_team_counts(teams)
    {
      teams: teams.map { |team| team_json(team) },
      message: message
    }
  end

  def team_detail_payload(team, message: nil)
    membership_page = [ params[:membership_page].to_i, 1 ].max
    membership_per_page = 50
    memberships = team.team_memberships.includes(:user).order(:id)
    membership_total = memberships.count
    {
      team: team_json(team),
      can_manage: TeamPolicy.new(Current.user, team).write?,
      memberships: memberships.offset((membership_page - 1) * membership_per_page).limit(membership_per_page).map { |m| team_membership_json(m) },
      membership_pagination: {
        page: membership_page,
        per_page: membership_per_page,
        total: membership_total,
        total_pages: (membership_total.to_f / membership_per_page).ceil
      },
      repository_grants: team.team_repositories.includes(:repository).order(:id).map { |g| team_repository_grant_json(g) },
      message: message
    }
  end

  def team_json(team)
    {
      id: team.id,
      name: team.name,
      member_count: team_count_for(@team_member_counts, team, :team_memberships),
      repository_count: team_count_for(@team_repository_counts, team, :team_repositories),
      owned_by_current_user: @current_user_owned_team_ids ? @current_user_owned_team_ids.include?(team.id) : team.owned_by?(Current.user),
      team_path: "/admin/teams/#{team.id}"
    }
  end

  def preload_team_counts(teams)
    ids = teams.map(&:id)
    @team_member_counts = TeamMembership.where(team_id: ids).group(:team_id).count
    @team_repository_counts = TeamRepository.where(team_id: ids).group(:team_id).count
    @current_user_owned_team_ids = TeamMembership.where(team_id: ids, user_id: Current.user.id, role: "owner").pluck(:team_id).to_set
  end

  def team_count_for(counts, team, association)
    return counts.fetch(team.id, 0) if counts

    team.public_send(association).count
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
