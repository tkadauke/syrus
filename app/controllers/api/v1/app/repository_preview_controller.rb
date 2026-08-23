module Api
  module V1
    module App
      # Job-less, repository-scoped preview of the current default branch —
      # same PreviewEnvironment/PreviewWorkspace/PreviewProxyMiddleware
      # machinery as JobPreviewController, keyed by repository_id instead of
      # job_id (PreviewEnvironment#job_id is nil for these rows).
      class RepositoryPreviewController < BaseController
        PREVIEW_BASE_DOMAIN = ENV.fetch("SYRUS_PREVIEW_BASE_DOMAIN", "lvh.me")

        def show
          repository = find_repository
          env = repository.preview_environments.order(created_at: :desc).first
          render json: { preview: env ? preview_json(env) : nil }
        end

        def logs
          repository = find_repository
          env = repository.preview_environments.order(created_at: :desc).first
          unless env
            render_error("not_found", "No preview environment found for this repository.", status: :not_found)
            return
          end

          begin
            logs = PreviewLogClient.call(env, lines: params.fetch(:lines, PreviewLogReader::DEFAULT_LINES))
          rescue PreviewLogClient::Unavailable
            render_error("preview_logs_unavailable", "Preview logs are temporarily unavailable.", status: :service_unavailable)
            return
          end

          render json: {
            preview: preview_json(env),
            logs: logs.map { |log| preview_log_json(log) }
          }
        end

        def create
          repository = find_repository
          if repository.archived?
            render_error("validation_failed", "Preview is not available for archived repositories.", status: :unprocessable_content)
            return
          end
          if repository.preview_environments.active.exists?
            render_error("conflict", "A preview environment is already active for this repository.", status: :conflict)
            return
          end
          env = repository.preview_environments.create!(state: "starting")
          render json: { preview: preview_json(env), message: "Preview environment starting." }, status: :created
        end

        def destroy
          repository = find_repository
          env = repository.preview_environments.active.first
          unless env
            render_error("not_found", "No active preview environment found for this repository.", status: :not_found)
            return
          end
          env.begin_stopping! if env.may_begin_stopping?
          env.save!
          render json: { preview: preview_json(env.reload), message: "Preview environment stopping." }
        end

        private

        def find_repository
          Current.user.repositories.find(params[:repository_id])
        end

        def preview_json(env)
          {
            id: env.id,
            state: env.state,
            url: env.running? ? env.preview_url(PREVIEW_BASE_DOMAIN) : nil,
            expires_at: env.expires_at&.iso8601,
            error_message: env.error_message
          }
        end

        def preview_log_json(log)
          {
            path: log.path,
            content: log.content,
            missing: log.missing
          }
        end
      end
    end
  end
end
