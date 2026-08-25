module Api
  module V1
    module App
      class JobDeployController < BaseController
        def show
          job = find_job
          workflow = latest_deploy_workflow(job)
          render json: { deploy: workflow ? deploy_json(workflow) : nil }
        end

        def create
          job = find_job
          unless job.deployable?
            render_error("validation_failed", "Deploy is only available for implemented, approved, or landing jobs, or landed jobs.", status: :unprocessable_content)
            return
          end
          unless job.approved? || ::App::DeployAvailability.allow_unapproved?(job.repository)
            render_error("forbidden", "Deploying an unapproved Job is disabled for #{job.repository.slug}. Approve the Job first, or set deploy.allow_unapproved in .syrus.yml.", status: :forbidden)
            return
          end
          if job.workflows.where(trigger_kind: "deploy", state: %w[queued running]).exists?
            render_error("conflict", "A deploy is already in progress for this job.", status: :conflict)
            return
          end

          workflow = WorkUnits::Launcher.instantiate(kind: "deploy", job: job)
          result = WorkUnits::Launcher.start!(workflow)

          if result.run
            render json: { deploy: deploy_json(workflow.reload), message: "Deploy workflow enqueued." }, status: :created
          else
            render_error("validation_failed", start_blocked_message(workflow.reload), status: :unprocessable_content)
          end
        end

        private

        def find_job
          find_job_by_ref(Current.user.jobs.includes(:repository), params[:job_id])
        end

        def latest_deploy_workflow(job)
          job.workflows.where(trigger_kind: "deploy").reorder(created_at: :desc, id: :desc).first
        end

        def deploy_json(workflow)
          {
            id: workflow.id,
            state: workflow.state,
            failure_reason: workflow.failure_reason,
            created_at: workflow.created_at&.iso8601,
            started_at: workflow.started_at&.iso8601,
            finished_at: workflow.finished_at&.iso8601,
            path: "#{job_path(workflow.job)}?tab=workflows#workflow-#{workflow.id}"
          }
        end

        def start_blocked_message(workflow)
          reason = WorkUnits::StartBlock.for(workflow).reason || workflow.artifact("start_cancelled_reason")
          if reason.present?
            "Blocked: #{reason.to_s.tr('_', ' ')} — see job card for details."
          else
            "Deploy workflow could not be started right now. Refresh and check the job card for details."
          end
        end
      end
    end
  end
end
