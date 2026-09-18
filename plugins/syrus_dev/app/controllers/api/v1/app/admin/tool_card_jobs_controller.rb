module Api
  module V1
    module App
      module Admin
        class ToolCardJobsController < BaseController
          def create
            return render json: { error: "syrus_dev_plugin_disabled" }, status: :not_found unless SyrusDev.enabled?

            result = ::SyrusDev::ToolCardJobCreator.new(user: Current.user).call(
              prompt: params[:prompt],
              screenshot: params[:screenshot]
            )

            if result.success?
              render json: {
                message: "Job created.",
                redirect_to: job_path(result.job),
                job: { id: result.job.id, job_path: job_path(result.job) }
              }, status: :created
            else
              render_error("validation_failed", result.error, status: :unprocessable_content)
            end
          end
        end
      end
    end
  end
end
