module Api
  module V1
    module App
      class JobPreviewController < BaseController
        PREVIEW_BASE_DOMAIN = ENV.fetch("SYRUS_PREVIEW_BASE_DOMAIN", "lvh.me")

        def show
          job = find_job
          env = job.preview_environments.order(created_at: :desc).first
          render json: { preview: env ? preview_json(env) : nil }
        end

        def logs
          job = find_job
          env = job.preview_environments.order(created_at: :desc).first
          unless env
            render_error("not_found", "No preview environment found for this job.", status: :not_found)
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
          job = find_job
          unless job.previewable?
            render_error("validation_failed", "Preview is only available for implemented, approved, or landing jobs.", status: :unprocessable_content)
            return
          end
          if job.preview_environments.active.exists?
            render_error("conflict", "A preview environment is already active for this job.", status: :conflict)
            return
          end
          env = job.preview_environments.create!(state: "starting")
          render json: { preview: preview_json(env), message: "Preview environment starting." }, status: :created
        end

        def destroy
          job = find_job
          env = job.preview_environments.active.first
          unless env
            render_error("not_found", "No active preview environment found for this job.", status: :not_found)
            return
          end
          env.begin_stopping! if env.may_begin_stopping?
          env.save!
          render json: { preview: preview_json(env.reload), message: "Preview environment stopping." }
        end

        private

        def find_job
          find_job_by_ref(Current.user.jobs.includes(:repository, :preview_environments), params[:job_id])
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
