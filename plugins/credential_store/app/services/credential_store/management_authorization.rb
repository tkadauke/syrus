module CredentialStore
  class ManagementAuthorization
    def initialize(user)
      @user = user
    end

    def visible_scope
      Credential.where(visible_relation)
    end

    def can_manage?(credential)
      can_manage_scope?(credential.scope_type, credential.scope_id)
    end

    def can_manage_scope?(scope_type, scope_id)
      return false unless user
      return true if user.admin?

      scope_policy(scope_type).can_manage?(user, scope_id)
    rescue KeyError
      false
    end

    def manageable_options
      {
        users: manageable_users.map { |candidate| user_option(candidate) },
        repositories: manageable_repositories.map { |repository| repository_option(repository) },
        teams: manageable_teams.map { |team| team_option(team) }
      }
    end

    private

    attr_reader :user

    def visible_relation
      return "1=0" unless user
      return "1=1" if user.admin?

      conditions = [
        Credential.sanitize_sql_for_conditions([ "(scope_type = ? AND scope_id = ?)", "user", user.id ])
      ]

      repository_ids = manageable_repositories.select(:id)
      conditions << Credential.sanitize_sql_for_conditions([ "(scope_type = ? AND scope_id IN (?))", "repository", repository_ids ]) if repository_ids.exists?

      team_ids = manageable_teams.select(:id)
      conditions << Credential.sanitize_sql_for_conditions([ "(scope_type = ? AND scope_id IN (?))", "team", team_ids ]) if team_ids.exists?

      conditions.join(" OR ")
    end

    def manageable_users
      return User.order(:email_address, :id) if user.admin?

      User.where(id: user.id)
    end

    def manageable_repositories
      if user.admin?
        Repository.order(:owner, :name, :id)
      else
        admin_direct_ids = RepositoryMembership.at_least("admin").where(user: user).select(:repository_id)
        team_ids = TeamMembership.where(user: user).select(:team_id)
        admin_team_ids = TeamRepository.at_least("admin").where(team_id: team_ids).select(:repository_id)
        Repository.where(id: admin_direct_ids).or(Repository.where(id: admin_team_ids)).order(:owner, :name, :id)
      end
    end

    def manageable_teams
      return Team.order(:name, :id) if user.admin?

      Team.joins(:team_memberships)
        .where(team_memberships: { user_id: user.id, role: "owner" })
        .distinct
        .order(:name, :id)
    end

    def user_option(candidate)
      {
        id: candidate.id,
        label: candidate.display_name,
        detail: candidate.email_address
      }
    end

    def repository_option(repository)
      {
        id: repository.id,
        label: repository.slug,
        detail: repository.archived? ? "archived" : nil
      }
    end

    def team_option(team)
      {
        id: team.id,
        label: team.name,
        detail: "#{team.team_memberships.count} members"
      }
    end

    def scope_policy(scope_type)
      CredentialStore::ManagementScope::Base.for(scope_type)
    end
  end
end
