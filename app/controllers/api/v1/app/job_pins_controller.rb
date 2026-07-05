module Api
  module V1
    module App
      class JobPinsController < BaseController
        def create
          job = find_job
          Current.user.job_pins.find_or_create_by!(job: job)
          broadcast_pin_change(job, pinned: true)

          render json: pin_payload(job, pinned: true, message: I18n.t("api.job_pins.pinned"))
        end

        def destroy
          job = find_job
          Current.user.job_pins.find_by(job: job)&.destroy!
          broadcast_pin_change(job, pinned: false)

          render json: pin_payload(job, pinned: false, message: I18n.t("api.job_pins.unpinned"))
        end

        private

        def find_job
          find_job_by_ref(Current.user.jobs, params[:job_id])
        end

        def pin_payload(job, pinned:, message:)
          {
            message: message,
            job: {
              id: job.id,
              pinned: pinned,
              job_path: job_path(job)
            },
            paths: {
              app_pin_path: "/api/v1/app/jobs/#{job.id}/pin",
              job_path: job_path(job)
            }
          }
        end

        def broadcast_pin_change(job, pinned:)
          AppEvents.broadcast(
            user: Current.user,
            type: "updated",
            resource: "job",
            id: job.id,
            changed: [ "pin" ],
            payload: { "pinned" => pinned }
          )
        end
      end
    end
  end
end
