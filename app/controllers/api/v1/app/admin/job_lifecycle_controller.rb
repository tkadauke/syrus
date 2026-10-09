module Api
  module V1
    module App
      module Admin
        class JobLifecycleController < Api::V1::App::JobLifecycleController
          before_action :require_admin

          def force_fail
            job = find_job
            unless job.may_force_fail?
              render_error("validation_failed", lifecycle_t("force_fail_unavailable", slug: job.slug, state: job.state), status: :unprocessable_content)
              return
            end

            job.force_fail!
            render_job(job.reload, message: lifecycle_t("force_failed"), changed: [ "state" ])
          end

          private

          def find_job
            find_job_by_ref(Job.includes(:repository), params[:job_id])
          end
        end
      end
    end
  end
end
