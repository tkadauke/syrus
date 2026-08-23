module Api
  module V1
    module App
      # Repository <-> Team access grants, scoped to repo `admin` tier via
      # RepositoryPolicy::Scope (see #find_repository) -- the same
      # authorization RepositoryMembershipsController uses. A repository
      # admin grants a team a role tier on this repository; every member of
      # that team then has at least that tier via
      # Repository#effective_role_for. Teams are purely additive: removing
      # every grant here returns the repository to the direct-membership-only
      # model.
      class RepositoryTeamGrantsController < BaseController
        include RepositoryMembersSerialization

        def index
          repository = find_repository
          render json: repository_members_payload(repository)
        end

        def create
          repository = find_repository

          role = params[:role].to_s
          unless TeamRepository::ROLES.include?(role)
            render_error("validation_failed", "Role must be one of #{TeamRepository::ROLES.join(', ')}.", status: :unprocessable_content)
            return
          end

          team = target_team_from_params
          unless team
            render_error("validation_failed", "No team found with that name.", status: :unprocessable_content)
            return
          end

          if repository.team_repositories.exists?(team_id: team.id)
            render_error("validation_failed", "#{team.name} already has a grant on this repository.", status: :unprocessable_content)
            return
          end

          repository.team_repositories.create!(team: team, role: role)
          render json: repository_members_payload(repository.reload).merge(message: "#{team.name} added as #{role}."), status: :created
        end

        def update
          repository = find_repository
          grant = repository.team_repositories.find(params[:id])

          role = params[:role].to_s
          unless TeamRepository::ROLES.include?(role)
            render_error("validation_failed", "Role must be one of #{TeamRepository::ROLES.join(', ')}.", status: :unprocessable_content)
            return
          end

          grant.update!(role: role)
          render json: repository_members_payload(repository.reload).merge(message: "Role updated to #{role}.")
        end

        def destroy
          repository = find_repository
          grant = repository.team_repositories.find(params[:id])
          grant.destroy!

          render json: repository_members_payload(repository.reload).merge(message: "#{grant.team.name} removed.")
        end

        private

        def find_repository
          policy_scope(Repository).find(params[:repository_id])
        end

        def target_team_from_params
          name = params[:team_name].to_s.strip
          return nil if name.blank?

          Team.find_by("lower(name) = ?", name.downcase)
        end
      end
    end
  end
end
