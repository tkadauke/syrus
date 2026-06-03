module Api
  module V1
    module App
      class JobClaimsController < BaseController
        def create
          job = find_job
          job.update!(claimed_by_user: Current.user, claimed_at: Time.current)
          render_claim(job.reload, message: "Job claimed.")
        end

        def destroy
          job = find_job
          unless job.claimed_by_user_id == Current.user.id
            render_error("forbidden", "Only the current owner can release this claim.", status: :forbidden)
            return
          end

          job.update!(claimed_by_user: nil, claimed_at: nil)
          render_claim(job.reload, message: "Job released.")
        end

        private

        def find_job
          Current.user.jobs.includes(:claimed_by_user).find(params[:job_id])
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
      end
    end
  end
end
