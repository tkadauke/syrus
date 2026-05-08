module Api
  module V1
    module Admin
      # Workflow-scoped admin actions exposed over the API.
      # Mirrors of JobsController#retry_step and the
      # WorkflowWorkspace.cleanup_for path that today only runs on
      # the daily prune job's schedule.
      #
      #   GET  /api/v1/admin/workflows/:id
      #   POST /api/v1/admin/workflows/:id/retry_step
      #   POST /api/v1/admin/workflows/:id/cleanup_workspace
      class WorkflowsController < BaseController
        # Single workflow's nested state (steps + runs + diagnostics
        # + claude_session metadata). Same per-record-resilience as
        # JobsController — a single bad row doesn't 500 the whole
        # response. Job envelope is included so the caller can drill
        # back up if needed.
        def show
          workflow = Workflow.includes(steps: :runs).find(params[:id])
          job = workflow.job
          render json: ::Admin::JobStateSerializer.workflow(workflow).merge(
            job: {
              id: job.id,
              state: job.state,
              repository: job.repository.slug,
              issue_number: job.issue_number,
              pr_number: job.pr_number
            }
          )
        end

        # Reopens the workflow + the failed step, creates a fresh
        # Run on the failed step, lets the inline-chain dispatch
        # take it from there. Same semantics as the HTML
        # JobsController#retry_step. Returns the new Run id.
        def retry_step
          workflow = Workflow.find(params[:id])

          unless workflow.failed?
            render_error("workflow_not_failed", "Workflow ##{workflow.id} is `#{workflow.state}`, not `failed`.", status: :unprocessable_entity)
            return
          end
          unless workflow.retry_available?
            render_error("workspace_cleaned_up", "Workspace already cleaned up; use Replay to start over.", status: :unprocessable_entity)
            return
          end

          failed_step = workflow.steps.where(state: "failed").order(:position).first
          unless failed_step
            render_error("no_failed_step", "No failed step found on Workflow ##{workflow.id}.", status: :unprocessable_entity)
            return
          end

          workflow.reopen!
          workflow.save!
          failed_step.reopen!
          failed_step.save!

          new_run = failed_step.runs.create!(
            job: workflow.job,
            trigger_kind: workflow.trigger_kind,
            agent_provider: workflow.agent_provider
          )

          render json: {
            ok: true,
            workflow_id: workflow.id,
            step_id: failed_step.id,
            new_run_id: new_run.id
          }
        end

        # Force the workspace teardown ahead of
        # WorkflowWorkspacePruneJob's daily sweep. Useful when the
        # operator wants to free PVC space immediately. Idempotent —
        # rm_rf no-ops if the dir is already gone, and the
        # cleaned_up_at column gets stamped either way.
        def cleanup_workspace
          workflow = Workflow.find(params[:id])
          ::WorkflowWorkspace.cleanup_for(workflow)
          render json: {
            ok: true,
            workflow_id: workflow.id,
            cleaned_up_at: workflow.reload.cleaned_up_at
          }
        end
      end
    end
  end
end
