module Api
  module V1
    module App
      class JobClaimsController < BaseController
        def create
          job = find_job
          return unless authorize_job_mutation!(job)
          if job.claimed_by_user_id.present? && job.claimed_by_user_id != Current.user.id
            render_error("validation_failed", "Job is already claimed by another user.", status: :unprocessable_content)
            return
          end

          job.update!(claimed_by_user: Current.user, claimed_at: Time.current)
          render_claim(job.reload, message: "Job claimed.")
        end

        def destroy
          job = find_job
          return unless authorize_job_mutation!(job)
          unless job.claimed_by_user_id == Current.user.id
            render_error("forbidden", "Only the current claimant can release this claim.", status: :forbidden)
            return
          end

          job.update!(claimed_by_user: nil, claimed_at: nil)
          render_claim(job.reload, message: "Job released.")
        end

        def update_owner
          job = find_job
          return unless authorize_job_mutation!(job)

          owner = find_owner_user
          return unless owner

          unless job.repository.member_at_least?(owner, "read")
            render_error("validation_failed", "Owner must have repository access.", status: :unprocessable_content)
            return
          end

          job.update!(owner_user: owner)
          render_claim(job.reload, message: "Job owner assigned.")
        end

        private

        def find_job
          find_job_by_ref(policy_scope(Job).includes(:repository, :owner_user, :claimed_by_user), params[:job_id])
        end

        def find_owner_user
          owner_user_id = params[:owner_user_id].presence || params.dig(:job, :owner_user_id).presence
          unless owner_user_id
            render_error("validation_failed", "Choose an owner.", status: :unprocessable_content)
            return nil
          end

          User.find_by(id: owner_user_id).tap do |owner|
            render_error("not_found", "Owner user not found.", status: :not_found) unless owner
          end
        end

        def render_claim(job, message:)
          AppEvents.broadcast(
            user: Current.user,
            type: "updated",
            resource: "job",
            id: job.id,
            changed: [ "claim" ]
          )

          render json: {
            message: message,
            job: {
              id: job.id,
              owner_user_id: job.owner_user_id,
              owner_user: owner_user_json(job.owner_user),
              claimed_at: job.claimed_at&.iso8601,
              claimed_by_user: owner_json(job.claimed_by_user),
              claimed_by_current_user: job.claimed_by_user_id == Current.user.id
            }
          }
        end

        def owner_json(user)
          return unless user

          {
            id: user.id,
            display_name: user.display_name,
            profile_path: profile_path(user)
          }
        end

        def owner_user_json(user)
          return unless user

          {
            id: user.id,
            email_address: user.email_address,
            display_name: user.display_name,
            profile_path: profile_path(user)
          }
        end
      end
    end
  end
end
