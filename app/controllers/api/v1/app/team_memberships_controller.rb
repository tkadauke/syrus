module Api
  module V1
    module App
      # Team member management. Mutations require owner-tier membership on
      # the team or global admin (TeamPolicy#write?) -- mirrors
      # RepositoryMembershipsController's admin-tier gate.
      class TeamMembershipsController < BaseController
        include TeamSerialization

        def create
          team = find_team
          return unless authorize_team_mutation!(team)

          role = params[:role].to_s
          unless TeamMembership::ROLES.include?(role)
            render_error("validation_failed", "Role must be one of #{TeamMembership::ROLES.join(', ')}.", status: :unprocessable_content)
            return
          end

          target_user = target_user_from_params
          unless target_user
            render_error("validation_failed", "No user found with that email.", status: :unprocessable_content)
            return
          end

          if team.team_memberships.exists?(user_id: target_user.id)
            render_error("validation_failed", "#{target_user.email_address} is already a member of this team.", status: :unprocessable_content)
            return
          end

          team.team_memberships.create!(user: target_user, role: role)
          render json: team_detail_payload(team.reload).merge(message: "#{target_user.email_address} added as #{role}."), status: :created
        end

        def update
          team = find_team
          return unless authorize_team_mutation!(team)

          membership = team.team_memberships.find(params[:id])

          role = params[:role].to_s
          unless TeamMembership::ROLES.include?(role)
            render_error("validation_failed", "Role must be one of #{TeamMembership::ROLES.join(', ')}.", status: :unprocessable_content)
            return
          end

          if role != "owner" && last_owner?(team, membership)
            render_error("validation_failed", "Cannot change the role of the last owner — promote another member to owner first.", status: :unprocessable_content)
            return
          end

          membership.update!(role: role)
          render json: team_detail_payload(team.reload).merge(message: "Role updated to #{role}.")
        end

        def destroy
          team = find_team
          return unless authorize_team_mutation!(team)

          membership = team.team_memberships.find(params[:id])

          if last_owner?(team, membership)
            render_error("validation_failed", "Cannot remove the last owner — promote another member to owner first.", status: :unprocessable_content)
            return
          end

          membership.destroy!
          render json: team_detail_payload(team.reload).merge(message: "Member removed.")
        end

        private

        def find_team
          policy_scope(Team).find(params[:team_id])
        end

        def authorize_team_mutation!(team)
          return true if TeamPolicy.new(Current.user, team).write?

          render_error("forbidden", "Only a team owner or an admin can perform this action.", status: :forbidden)
          false
        end

        def last_owner?(team, membership)
          membership.role == "owner" && team.team_memberships.where(role: "owner").count <= 1
        end

        def target_user_from_params
          email = params[:email].to_s.strip
          return nil if email.blank?

          User.find_by(email_address: email.downcase)
        end
      end
    end
  end
end
