module Api
  module V1
    module App
      class EventActionsController < BaseController
        def file_job
          result = Observability::EventJobFiler.new(
            user: Current.user,
            event_type: params.require(:event_type),
            event_id: params.require(:event_id)
          ).call

          if result.error_code == "forbidden"
            render_error("forbidden", result.error_message, status: :forbidden)
          elsif result.error_code == "not_found"
            render_error("not_found", result.error_message, status: :not_found)
          elsif result.error_code.present? || result.error_message.present?
            render_error(result.error_code || "validation_failed", result.error_message, status: :unprocessable_content)
          elsif result.job
            render json: { message: "Job filed.", job_id: result.job.id }, status: :created
          else
            render json: { message: "Issue filed.", issue_url: result.issue_url }, status: :created
          end
        end
      end
    end
  end
end
