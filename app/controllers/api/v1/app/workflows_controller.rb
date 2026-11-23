module Api
  module V1
    module App
      class WorkflowsController < BaseController
        def preview
          workflow = find_workflow
          render json: { workflow: ::App::JobDetailPayload.workflow_preview(workflow: workflow, user: Current.user) }
        end

        def detail
          workflow = find_workflow
          render json: ::App::JobDetailPayload.workflow_detail(workflow: workflow, user: Current.user)
        end

        def visual_artifact
          workflow = find_workflow
          attachment = workflow.visual_artifact_for(params[:type].to_s.strip)
          raise ActiveRecord::RecordNotFound, "Visual artifact not found" unless attachment

          send_secure_blob(attachment.blob, immutable: true)
        rescue StandardError => e
          raise unless StorageConnectivity.transient_error?(e)
          raise if response.committed?

          Rails.logger.warn(
            "[WorkflowsController] Active Storage unavailable while serving visual artifact " \
            "for Workflow ##{workflow&.id}: #{e.class}: #{e.message}"
          )
          expires_now
          response.set_header("Retry-After", StorageConnectivity::RETRY_AFTER_SECONDS.to_s)
          render json: {
            error: {
              code: "storage_unavailable",
              message: "Visual artifact storage is temporarily unavailable. Please retry shortly."
            }
          }, status: :service_unavailable
        end

        private

        def find_workflow
          readable_jobs = if Current.user.admin?
            Job.visible_to(Current.user, scope: Job.all)
          else
            Job.visible_to(Current.user, scope: Job.where(user: Current.user).or(Job.accessible_to(Current.user)))
          end
          workflow_scope = Workflow.joins(:job).merge(restrict_invocation_relation(readable_jobs))
          restrict_invocation_relation(workflow_scope).find(params[:workflow_id])
        end
      end
    end
  end
end
