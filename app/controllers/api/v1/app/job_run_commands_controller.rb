module Api
  module V1
    module App
      class JobRunCommandsController < BaseController
        def poll_feedback
          job = find_job
          unless job.open? && job.pr_number.present?
            render_error("validation_failed", "Can only check feedback on open Jobs that have a PR.", status: :unprocessable_content)
            return
          end

          agent_provider = params[:agent_provider].to_s.presence
          return unless valid_configured_agent_provider?(agent_provider)

          job.switch_agent_provider!(agent_provider) if agent_provider.present?
          if agent_provider.present?
            PollPullRequestJob.perform_later(job.id, manual: true, agent_provider: agent_provider)
          else
            PollPullRequestJob.perform_later(job.id, manual: true)
          end

          notice = agent_provider.present? ? "Checking PR feedback with #{agent_provider.titleize} now..." : "Checking PR feedback now..."
          render_job(job.reload, message: notice, changed: [ "feedback" ])
        end

        def resume
          job = find_job
          source_run = job.runs.find_by(id: params[:source_run_id])
          unless source_run
            render_error("not_found", "Source Run not found.", status: :not_found)
            return
          end
          unless %w[ failed cancelled ].include?(source_run.state)
            render_error("validation_failed", "Only failed or cancelled Runs are resumable.", status: :unprocessable_content)
            return
          end

          session = source_run.claude_session
          unless session
            render_error("validation_failed", "No agent session captured for that Run - try Retry instead.", status: :unprocessable_content)
            return
          end

          workflow = Workflows::Resume.instantiate(job: job, agent_provider: session.provider)
          run = StepDispatcher.start_workflow(
            workflow,
            parent_session_id: session.session_id,
            prompt: Prompts::Resume.new.to_s
          )

          render_job(job.reload, message: "Resume workflow enqueued.", changed: [ "workflows", "runs" ], run: run&.reload, workflow: workflow.reload, tab: "workflows")
        end

        def check_mergeability
          job = find_job
          unless job.pr_number.present? || job.external_pr_number.present?
            render_error("validation_failed", "No PR on this Job to check.", status: :unprocessable_content)
            return
          end

          PollRebaseJob.perform_later(job.id, bypass_cache: true)
          render_job(job.reload, message: "Checking mergeability now...", changed: [ "mergeability" ])
        end

        def rebase
          job = find_job
          unless job.pr_number.present? || job.external_pr_number.present?
            render_error("validation_failed", "No PR on this Job to rebase.", status: :unprocessable_content)
            return
          end
          if RebaseWorkflowSelector.active_for_stack?(job)
            render_error("validation_failed", "A rebase is already in progress - wait for it to finish.", status: :unprocessable_content)
            return
          end

          agent_provider = params[:agent_provider].to_s.presence
          return unless valid_configured_agent_provider?(agent_provider)

          job.switch_agent_provider!(agent_provider) if agent_provider.present?
          workflow = RebaseWorkflowSelector.instantiate(
            job: job,
            agent_provider: agent_provider,
            pr: rebase_pull_request_snapshot(job)
          )
          run = StepDispatcher.start_workflow(workflow)

          notice = agent_provider.present? ? "Rebase workflow enqueued with #{agent_provider.titleize}." : "Rebase workflow enqueued."
          render_job(job.reload, message: notice, changed: [ "workflows", "runs" ], run: run&.reload, workflow: workflow.reload, tab: "workflows")
        end

        def stop_run
          job = find_job
          run = job.runs.find_by(id: params[:run_id])
          unless run
            render_error("not_found", "Run not found.", status: :not_found)
            return
          end
          unless run.may_cancel?
            render_error("validation_failed", "Run is not active.", status: :unprocessable_content)
            return
          end

          run.cancel!
          run.save!
          render_job(job.reload, message: "Run stopped.", changed: [ "runs" ], run: run.reload)
        end

        def retry_step
          job = find_job
          workflow = job.workflows.find_by(id: params[:workflow_id])
          unless workflow
            render_error("not_found", "Workflow not found.", status: :not_found)
            return
          end
          unless workflow.failed?
            render_error("validation_failed", "Workflow is not in a failed state.", status: :unprocessable_content)
            return
          end
          unless workflow.retry_available?
            render_error("validation_failed", "Workspace already cleaned up - use Start over.", status: :unprocessable_content)
            return
          end

          failed_step = workflow.steps.where(state: "failed").order(:position).first
          unless failed_step
            render_error("validation_failed", "No failed step to retry.", status: :unprocessable_content)
            return
          end

          result = RetryFailedStepEnqueuer.call(workflow: workflow)
          unless result.success?
            render_error("validation_failed", result.error, status: :unprocessable_content)
            return
          end

          render_job(
            job.reload,
            message: "Retrying #{result.step.kind} for workflow ##{workflow.id}...",
            changed: [ "workflows", "runs" ],
            run: result.run.reload,
            workflow: result.workflow.reload,
            tab: "workflows"
          )
        end

        def push_commits
          job = find_job
          workflow = job.workflows.find_by(id: params[:workflow_id])
          unless workflow
            render_error("not_found", "Workflow not found.", status: :not_found)
            return
          end
          unless workflow.failed? && workflow.cleaned_up_at.nil?
            render_error("validation_failed", "Workspace is not available for this workflow.", status: :unprocessable_content)
            return
          end

          PushPendingCommitsJob.perform_later(workflow.id)
          render_job(job.reload, message: "Pushing commits to GitHub...", changed: [ "workflows" ], workflow: workflow)
        end

        def diagnose
          job = find_job
          run = job.runs.find_by(id: params[:run_id])
          unless run
            render_error("not_found", "Run not found.", status: :not_found)
            return
          end
          unless run.queued? || run.running?
            render_error("validation_failed", "Diagnose is only available for active runs.", status: :unprocessable_content)
            return
          end

          DiagnoseRunJob.perform_later(run.id)
          render_job(job.reload, message: "Diagnostic queued - snapshot will appear shortly.", changed: [ "diagnostics" ], run: run)
        end

        private

        def find_job
          Current.user.jobs.includes(:repository, :runs, workflows: :steps).find(params[:job_id])
        end

        def valid_configured_agent_provider?(agent_provider)
          return true if agent_provider.blank?
          return true if Current.user.agent_provider_configured?(agent_provider)

          render_error("validation_failed", "That agent is not configured.", status: :unprocessable_content)
          false
        end

        def rebase_pull_request_snapshot(job)
          pr_number = job.pr_number || job.external_pr_number
          return if pr_number.blank?

          GithubClient.for(repository: job.repository, user: job.user)
                      .pull_request(job.repository.slug, pr_number, bypass_cache: true)
        rescue StandardError => e
          Rails.logger.info("[App::JobRunCommandsController] failed to load PR ##{pr_number} for rebase job #{job.id}: #{e.class}: #{e.message}")
          nil
        end

        def render_job(job, message:, changed:, run: nil, workflow: nil, tab: nil)
          broadcast_job_change(job, changed)
          payload = job_payload(job, message: message, tab: tab)
          payload[:run] = run_json(run) if run
          payload[:workflow] = workflow_json(workflow) if workflow
          render json: payload
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

        def job_payload(job, message:, tab:)
          {
            message: message,
            job: {
              id: job.id,
              state: job.state,
              closure_reason: job.closure_reason,
              agent_provider: job.agent_provider,
              pr_number: job.pr_number,
              external_pr_number: job.external_pr_number,
              pr_mergeable: job.pr_mergeable,
              pr_mergeable_checked_at: job.pr_mergeable_checked_at&.iso8601,
              runs_count: job.runs.size,
              workflows_count: job.workflows.size
            },
            paths: {
              job_path: tab ? job_path(job, tab: tab) : job_path(job)
            }
          }
        end

        def run_json(run)
          {
            id: run.id,
            state: run.state,
            trigger_kind: run.trigger_kind,
            agent_provider: run.agent_provider,
            workflow_id: run.workflow_id,
            step_id: run.step_id,
            parent_session_id: run.parent_session_id,
            queued_at: run.created_at&.iso8601,
            started_at: run.started_at&.iso8601,
            finished_at: run.finished_at&.iso8601
          }
        end

        def workflow_json(workflow)
          {
            id: workflow.id,
            state: workflow.state,
            trigger_kind: workflow.trigger_kind,
            agent_provider: workflow.agent_provider,
            cleaned_up_at: workflow.cleaned_up_at&.iso8601,
            steps_count: workflow.steps.size,
            runs_count: workflow.steps.sum { |step| step.runs.size }
          }
        end
      end
    end
  end
end
