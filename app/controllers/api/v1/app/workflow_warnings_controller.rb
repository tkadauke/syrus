module Api
  module V1
    module App
      class WorkflowWarningsController < BaseController
        def file_job
          job = find_job
          warning = find_warning(job)
          return unless warning

          result = WorkflowWarnings::FileFixJob.call(warning: warning, actor: Current.user, prompt: params[:prompt])
          unless result.ok?
            render_error("validation_failed", result.message, status: :unprocessable_content)
            return
          end

          render json: {
            message: result.message,
            warning: warning_json(result.warning),
            job: created_job_summary_json(result.job)
          }, status: :created
        end

        def dismiss
          job = find_job
          warning = find_warning(job)
          return unless warning

          unless warning.dismiss!
            render_error("validation_failed", "Warning cannot be dismissed (already dismissed).", status: :unprocessable_content)
            return
          end

          render json: {
            message: "Warning dismissed.",
            warning: warning_json(warning.reload)
          }
        end

        private

        def find_job
          find_job_by_ref(Current.user.jobs, params[:job_id])
        end

        def find_warning(job)
          warning = job.workflow_warnings.find_by(id: params[:id])
          unless warning
            render_error("not_found", "Warning not found.", status: :not_found)
            return nil
          end
          warning
        end

        def warning_json(warning)
          {
            id: warning.id,
            kind: warning.kind,
            severity: warning.severity,
            title: warning.redacted_title,
            evidence: warning.redacted_evidence,
            suggested_prompt: warning.redacted_suggested_prompt,
            state: warning.state,
            step_id: warning.step_id,
            created_job_id: warning.created_job_id,
            created_at: warning.created_at&.iso8601
          }
        end

        def created_job_summary_json(job)
          {
            id: job.id,
            slug: job.slug,
            title: job.issue_title,
            state: job.state,
            job_path: job_path(job)
          }
        end
      end
    end
  end
end
