module Api
  module V1
    module App
      # Final-approver list management for a repository's `final_say`
      # review policy (see ReviewPolicies::FinalSayPolicy), scoped to repo
      # `admin` tier via RepositoryPolicy::Scope (see #find_repository) --
      # same admin-only gating pattern as RepositoryMembershipsController.
      class RepositoryFinalApproversController < BaseController
        def index
          repository = find_repository
          render json: final_approvers_payload(repository)
        end

        def create
          repository = find_repository

          target_user = target_user_from_params
          unless target_user
            render_error("validation_failed", "No user found with that email.", status: :unprocessable_content)
            return
          end

          if repository.repository_final_approvers.exists?(user_id: target_user.id)
            render_error("validation_failed", "#{target_user.email_address} is already a final approver for this repository.", status: :unprocessable_content)
            return
          end

          repository.repository_final_approvers.create!(user: target_user)
          render json: final_approvers_payload(repository.reload).merge(message: "#{target_user.email_address} added as final approver."), status: :created
        end

        def destroy
          repository = find_repository
          approver = repository.repository_final_approvers.find(params[:id])
          approver.destroy!

          render json: final_approvers_payload(repository.reload).merge(message: "Final approver removed.")
        end

        private

        def find_repository
          policy_scope(Repository).find(params[:repository_id])
        end

        def final_approvers_payload(repository)
          {
            final_approvers: repository.repository_final_approvers.includes(:user).order(:created_at).map do |approver|
              {
                id: approver.id,
                created_at: approver.created_at.iso8601,
                user: {
                  id: approver.user.id,
                  name: approver.user.display_name,
                  email_address: approver.user.email_address
                }
              }
            end
          }
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
