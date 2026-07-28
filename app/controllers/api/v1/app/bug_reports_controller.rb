module Api
  module V1
    module App
      class BugReportsController < BaseController
        def create
          result = ::BugReports::Router.new(user: Current.user).call(
            title: params[:title],
            description: params[:description],
            screenshot: params[:screenshot],
            attachments: Array(params[:attachments]).compact
          )

          if result.error_code == "github_token_required"
            render_error("github_token_required", result.error_message, status: :unprocessable_content)
          elsif result.error_message.present?
            render_error("validation_failed", result.error_message, status: :unprocessable_content)
          elsif result.job
            render json: { message: "Bug report queued.", job_id: result.job.id }, status: :created
          else
            render json: { message: "Bug report filed.", issue_url: result.issue_url }, status: :created
          end
        end
      end
    end
  end
end
