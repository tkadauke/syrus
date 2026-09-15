module Api
  module V1
    module App
      class BugReportsController < BaseController
        def create
          result = ::BugReports::Router.new(user: Current.user).call(
            title: params[:title],
            description: params[:description],
            screenshot: params[:screenshot],
            attachments: Array(params[:attachments]).compact,
            context: params[:context]
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

        def chat
          router = ::BugReports::Router.new(user: Current.user)
          repository = router.target_repository
          unless repository
            render_error("validation_failed", "Bug report chats are only available when this instance can file Syrus Jobs for bug reports.", status: :unprocessable_content)
            return
          end

          result = ::BugReports::ChatStarter.new(user: Current.user, repository: repository).call(
            title: params[:title],
            description: params[:description],
            screenshot: params[:screenshot],
            attachments: Array(params[:attachments]).compact,
            context: params[:context]
          )

          if result.success?
            render json: { message: "Chat started.", redirect_to: chat_path(result.chat_session), chat_id: result.chat_session.id }, status: :created
          else
            render_error("validation_failed", result.error.presence || "Chat could not be started.", status: :unprocessable_content)
          end
        end
      end
    end
  end
end
