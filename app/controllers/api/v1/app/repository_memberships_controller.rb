module Api
  module V1
    module App
      # Repository member management, scoped to repo `admin` tier via
      # RepositoryPolicy::Scope (see #find_repository). Lets a repository
      # admin list current members, add a user by email at a chosen role,
      # change an existing member's role, and remove a member.
      class RepositoryMembershipsController < BaseController
        include RepositoryTabsSerialization

        def index
          repository = find_repository
          render json: memberships_payload(repository)
        end

        def create
          repository = find_repository

          role = params[:role].to_s
          unless RepositoryMembership::ROLES.include?(role)
            render_error("validation_failed", "Role must be one of #{RepositoryMembership::ROLES.join(', ')}.", status: :unprocessable_content)
            return
          end

          target_user = target_user_from_params
          unless target_user
            render_error("validation_failed", "No user found with that email.", status: :unprocessable_content)
            return
          end

          if repository.repository_memberships.exists?(user_id: target_user.id)
            render_error("validation_failed", "#{target_user.email_address} is already a member of this repository.", status: :unprocessable_content)
            return
          end

          repository.repository_memberships.create!(user: target_user, role: role)
          render json: memberships_payload(repository.reload).merge(message: "#{target_user.email_address} added as #{role}."), status: :created
        end

        def update
          repository = find_repository
          membership = repository.repository_memberships.find(params[:id])

          role = params[:role].to_s
          unless RepositoryMembership::ROLES.include?(role)
            render_error("validation_failed", "Role must be one of #{RepositoryMembership::ROLES.join(', ')}.", status: :unprocessable_content)
            return
          end

          if role != "admin" && last_admin?(repository, membership)
            render_error("validation_failed", "Cannot change the role of the last admin — promote another member to admin first.", status: :unprocessable_content)
            return
          end

          membership.update!(role: role)
          render json: memberships_payload(repository.reload).merge(message: "Role updated to #{role}.")
        end

        def destroy
          repository = find_repository
          membership = repository.repository_memberships.find(params[:id])

          if last_admin?(repository, membership)
            render_error("validation_failed", "Cannot remove the last admin — promote another member to admin first.", status: :unprocessable_content)
            return
          end

          membership.destroy!
          render json: memberships_payload(repository.reload).merge(message: "Member removed.")
        end

        private

        def find_repository
          policy_scope(Repository).find(params[:repository_id])
        end

        def last_admin?(repository, membership)
          membership.role == "admin" && repository.repository_memberships.at_least("admin").count <= 1
        end

        def target_user_from_params
          email = params[:email].to_s.strip
          return nil if email.blank?

          User.find_by(email_address: email.downcase)
        end

        def memberships_payload(repository)
          {
            repository: {
              id: repository.id,
              slug: repository.slug,
              repository_path: repository_path(repository)
            },
            tabs: repository_tabs_json(repository),
            memberships: repository.repository_memberships.includes(:user).order(:id).map { |m| membership_json(m) }
          }
        end

        def membership_json(membership)
          {
            id: membership.id,
            role: membership.role,
            agent_provider: membership.agent_provider,
            created_at: membership.created_at.iso8601,
            user: {
              id: membership.user.id,
              email_address: membership.user.email_address,
              name: membership.user.display_name
            }
          }
        end
      end
    end
  end
end
