module Api
  module V1
    module App
      class JobPreviewController < BaseController
        PREVIEW_BASE_DOMAIN = ENV.fetch("SYRUS_PREVIEW_BASE_DOMAIN", "lvh.me")

        def show
          job = find_job
          env = job.preview_environments.order(created_at: :desc).first
          render json: { preview: env ? preview_json(env) : nil, preview_projects: preview_projects(job).to_a, unavailable_reason: preview_projects(job).unavailable_reason }
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
            render_error("validation_failed", "Preview is only available for implemented, approved, or landing jobs, or landed jobs.", status: :unprocessable_content)
            return
          end
          if job.preview_environments.active.exists?
            render_error("conflict", "A preview environment is already active for this job.", status: :conflict)
            return
          end
          selection = preview_projects(job)
          unless selection.available?
            render_error("preview_unavailable", preview_unavailable_message(selection), status: :unprocessable_content)
            return
          end
          project = selected_preview_project(selection)
          unless project
            render_error("preview_project_required", "Choose which affected project to preview.", status: :unprocessable_content)
            return
          end

          env = job.preview_environments.create!(state: "starting", project_id: project.id)
          render json: { preview: preview_json(env, project: project), preview_projects: selection.to_a, message: "Preview environment starting." }, status: :created
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

        def preview_json(env, project: nil)
          project ||= preview_project_for(env)
          {
            id: env.id,
            state: env.state,
            url: env.running? ? env.preview_url(PREVIEW_BASE_DOMAIN) : nil,
            expires_at: env.expires_at&.iso8601,
            error_message: env.error_message,
            error_reason: env.error_reason,
            project_id: env.project_id,
            project_label: project&.label
          }
        end

        def preview_projects(job)
          @preview_projects ||= ::App::PreviewProjects.for_job(job)
        end

        def selected_preview_project(selection)
          return selection.choices.first if selection.single?

          selection.choice(params[:project_id])
        end

        def preview_project_for(env)
          return nil if env.project_id.blank?

          ::App::PreviewProjects.for_job(env.job).choice(env.project_id)
        end

        def preview_unavailable_message(selection)
          if selection.unavailable_reason == "no_affected_preview_project"
            "No affected project has a preview configured."
          else
            "No preview is configured for this repository."
          end
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
