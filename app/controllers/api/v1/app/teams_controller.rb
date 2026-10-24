module Api
  module V1
    module App
      # Team CRUD. Visible to a team's own members (any role) and to global
      # admins (TeamPolicy::Scope); mutations (rename, destroy) require
      # owner-tier membership or global admin (TeamPolicy#write?). Any
      # authenticated user may create a team -- they become its first owner,
      # mirroring Repository#seed_owner_membership.
      class TeamsController < BaseController
        include TeamSerialization

        def index
          render json: teams_payload
        end

        def show
          render json: team_detail_payload(find_team)
        end

        def create
          name = params.dig(:team, :name).to_s.strip
          if name.blank?
            render_error("validation_failed", I18n.t("api.teams.name_blank"), status: :unprocessable_content)
            return
          end

          team = Team.new(name: name)
          Team.transaction do
            team.save!
            team.team_memberships.create!(user: Current.user, role: "owner")
          end

          render json: teams_payload(message: I18n.t("api.teams.created", name: team.name)), status: :created
        rescue ActiveRecord::RecordInvalid => e
          render_error("validation_failed", e.record.errors.full_messages.to_sentence, status: :unprocessable_content)
        end

        def update
          team = find_team
          return unless authorize_team_mutation!(team)

          name = params.dig(:team, :name).to_s.strip
          if name.blank?
            render_error("validation_failed", I18n.t("api.teams.name_blank"), status: :unprocessable_content)
            return
          end

          if team.update(name: name)
            render json: team_detail_payload(team, message: I18n.t("api.teams.renamed", name: team.name))
          else
            render_error("validation_failed", team.errors.full_messages.to_sentence, status: :unprocessable_content)
          end
        end

        def destroy
          team = find_team
          return unless authorize_team_mutation!(team)

          name = team.name
          team.destroy!
          render json: teams_payload(message: I18n.t("api.teams.deleted", name: name))
        end

        private

        def find_team
          policy_scope(Team).find(params[:id])
        end

        def authorize_team_mutation!(team)
          return true if TeamPolicy.new(Current.user, team).write?

          render_error("forbidden", I18n.t("api.teams.owner_forbidden"), status: :forbidden)
          false
        end
      end
    end
  end
end
