module Api
  module V1
    module App
      # Job-scoped ref-movement action dispatch (EPIC-268 Story 11). Only
      # `send_job_upstream` is job-scoped today — `submit_branch_upstream`
      # operates on a repository track branch, not a single Job, and is
      # dispatched from the repository Delivery section instead. Reuses
      # `RefMovementAction.dispatch!` (the same primitive the
      # `dispatch_ref_movement_action` MCP tool calls) so this is just an
      # authenticated REST entry point, not a second implementation.
      class JobRefMovementActionsController < BaseController
        ALLOWED_ACTIONS = %w[send_job_upstream].freeze

        def create
          job = find_mutable_job
          return unless authorize_job_mutation!(job)

          action_name = params[:action_name].to_s
          unless ALLOWED_ACTIONS.include?(action_name)
            render_error("validation_failed", "#{action_name.presence || "(blank)"} cannot be dispatched from a Job.", status: :unprocessable_content)
            return
          end

          ref_movement_action = RefMovementAction.dispatch!(
            repository: job.repository,
            actor: Current.user,
            action: action_name,
            source: job
          )

          if ref_movement_action.dispatched?
            broadcast_job_change(job.reload, [ "pr_links", "workflows", "runs" ])
            render json: { message: "Sent upstream.", ref_movement_action_id: ref_movement_action.id }
          else
            render_error("validation_failed", ref_movement_action.blocked_reason || "Ref-movement action blocked.", status: :unprocessable_content)
          end
        end

        private

        def find_mutable_job
          find_job_by_ref(policy_scope(Job).includes(:repository), params[:job_id])
        end

        def broadcast_job_change(job, changed)
          AppEvents.broadcast(
            user: Current.user,
            type: "updated",
            resource: "job",
            id: job.id,
            changed: changed
          )
        end
      end
    end
  end
end
