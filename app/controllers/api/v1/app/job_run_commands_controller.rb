module Api
  module V1
    module App
      class JobRunCommandsController < BaseController
        before_action :load_job
        before_action :authorize_job_command

        def poll_feedback
          job = @job
          unless job.open? && job.pr_number.present?
            render_error("validation_failed", t("api.job_run_commands.errors.feedback_requires_open_job_with_pr"), status: :unprocessable_content)
            return
          end

          agent_provider = params[:agent_provider].to_s.presence
          return unless valid_configured_agent_provider?(agent_provider)

          if agent_provider.present?
            PollPullRequestJob.perform_later(job.id, manual: true, agent_provider: agent_provider)
          else
            PollPullRequestJob.perform_later(job.id, manual: true)
          end

          notice = if agent_provider.present?
            t("api.job_run_commands.notices.checking_feedback_with_agent", agent: agent_provider.titleize)
          else
            t("api.job_run_commands.notices.checking_feedback")
          end
          render_job(job.reload, message: notice, changed: [ "feedback" ])
        end

        def resume
          job = @job
          source_run = job.runs.find_by(id: params[:source_run_id])
          unless source_run
            render_error("not_found", t("api.job_run_commands.errors.source_run_not_found"), status: :not_found)
            return
          end
          result = ResumeWorkflowEnqueuer.call(job: job, source_run: source_run)
          unless result.success?
            render_error("validation_failed", result.error, status: :unprocessable_content)
            return
          end

          render_job(job.reload, message: t("api.job_run_commands.notices.resume_enqueued"), changed: [ "workflows", "runs" ], run: result.run.reload, workflow: result.workflow.reload, tab: "workflows")
        end

        def check_mergeability
          job = @job
          unless job.pr_number.present? || job.external_pr_number.present?
            render_error("validation_failed", t("api.job_run_commands.errors.no_pr_to_check"), status: :unprocessable_content)
            return
          end

          PollRebaseJob.enqueue_manual_check(job.id)
          render_job(job.reload, message: t("api.job_run_commands.notices.checking_mergeability"), changed: [ "mergeability" ])
        end

        def recheck_pr_checks
          job = @job
          unless job.pr_number.present? || job.external_pr_number.present?
            render_error("validation_failed", t("api.job_run_commands.errors.no_pr_to_recheck"), status: :unprocessable_content)
            return
          end

          PollPullRequestJob.perform_later(job.id, manual: true)
          PollMainBranchHealthJob.perform_later(job.repository_id, manual: true) if job.repository.main_branch_health_enabled?
          LandingQueueProcessorJob.perform_later

          render_job(job.reload, message: t("api.job_run_commands.notices.rechecking_pr_checks"), changed: [ "checks", "mergeability" ])
        end

        def rebase
          job = @job
          unless job.pr_number.present? || job.external_pr_number.present?
            render_error("validation_failed", t("api.job_run_commands.errors.no_pr_to_rebase"), status: :unprocessable_content)
            return
          end
          if RebaseWorkflowSelector.active_for_stack?(job)
            render_error("validation_failed", t("api.job_run_commands.errors.rebase_in_progress"), status: :unprocessable_content)
            return
          end
          if RebaseWorkflowSelector.active_merge_train_for_stack?(job)
            render_error("validation_failed", t("api.job_run_commands.errors.merge_train_active"), status: :unprocessable_content)
            return
          end

          agent_provider = params[:agent_provider].to_s.presence
          return unless valid_configured_agent_provider?(agent_provider)

          superseded_active_workflow = RebaseWorkflowSelector
            .related_jobs_for(job)
            .map(&:cancel_active_workflows_for_rebase!)
            .any?

          workflow = RebaseWorkflowSelector.instantiate(
            job: job,
            agent_provider: agent_provider,
            pr: rebase_pull_request_snapshot(job),
            requested_by: "user"
          )
          run = WorkUnits::Launcher.start!(workflow).run

          notice = if agent_provider.present?
            t("api.job_run_commands.notices.rebase_enqueued_with_agent", agent: agent_provider.titleize)
          else
            t("api.job_run_commands.notices.rebase_enqueued")
          end
          notice = t("api.job_run_commands.notices.workflow_cancelled_for_rebase", notice: notice) if superseded_active_workflow
          render_job(job.reload, message: notice, changed: [ "workflows", "runs" ], run: run&.reload, workflow: workflow.reload, tab: "workflows")
        end

        def retry_pr_ingestion
          job = @job
          unless job.external_pr?
            render_error("validation_failed", t("api.job_run_commands.errors.external_pr_required"), status: :unprocessable_content)
            return
          end

          result = ExternalPrIngestRetryEnqueuer.call(job: job)
          unless result.success?
            render_error("validation_failed", result.error, status: :unprocessable_content)
            return
          end

          render_job(
            job.reload,
            message: t("api.job_run_commands.notices.retrying_pr_ingestion"),
            changed: [ "workflows", "runs", "state" ],
            workflow: result.workflow.reload,
            tab: "workflows"
          )
        end

        def run_visual_review
          job = @job
          result = ManualVisualReviewSubmission.call(job: job)
          unless result.success?
            render_error("validation_failed", result.error, status: :unprocessable_content)
            return
          end

          render_job(job.reload, message: t("api.job_run_commands.notices.visual_review_enqueued"), changed: [ "workflows", "runs" ], run: result.run&.reload, workflow: result.workflow.reload, tab: "workflows")
        end

        def run_visual_diff
          job = @job
          result = VisualDiffSubmission.call(job: job)
          unless result.success?
            render_error("validation_failed", result.error, status: :unprocessable_content)
            return
          end

          render_job(job.reload, message: t("api.job_run_commands.notices.visual_diff_enqueued"), changed: [ "workflows", "runs" ], run: result.run&.reload, workflow: result.workflow.reload, tab: "workflows")
        end

        def stop_run
          job = @job
          run = job.runs.find_by(id: params[:run_id])
          unless run
            render_error("not_found", t("api.job_run_commands.errors.run_not_found"), status: :not_found)
            return
          end
          unless run.may_cancel?
            render_error("validation_failed", t("api.job_run_commands.errors.run_not_active"), status: :unprocessable_content)
            return
          end

          run.cancel!
          run.save!
          render_job(job.reload, message: t("api.job_run_commands.notices.run_stopped"), changed: [ "runs" ], run: run.reload)
        end

        def retry_step
          job = @job
          workflow = job.workflows.find_by(id: params[:workflow_id])
          unless workflow
            render_error("not_found", t("api.job_run_commands.errors.workflow_not_found"), status: :not_found)
            return
          end
          unless workflow.failed?
            render_error("validation_failed", t("api.job_run_commands.errors.workflow_not_failed"), status: :unprocessable_content)
            return
          end
          unless workflow.retry_available?
            render_error("validation_failed", t("api.job_run_commands.errors.workspace_cleaned_up"), status: :unprocessable_content)
            return
          end

          failed_step = RetryFailedStepEnqueuer.failed_step_for(workflow)
          unless failed_step
            render_error("validation_failed", t("api.job_run_commands.errors.no_failed_step"), status: :unprocessable_content)
            return
          end

          result = RetryFailedStepEnqueuer.call(workflow: workflow)
          unless result.success?
            render_error("validation_failed", result.error, status: :unprocessable_content)
            return
          end

          render_job(
            job.reload,
            message: t("api.job_run_commands.notices.retrying_step", step: result.step.kind, workflow: workflow.slug),
            changed: [ "workflows", "runs" ],
            run: result.run.reload,
            workflow: result.workflow.reload,
            tab: "workflows"
          )
        end

        def push_commits
          job = @job
          workflow = job.workflows.find_by(id: params[:workflow_id])
          unless workflow
            render_error("not_found", t("api.job_run_commands.errors.workflow_not_found"), status: :not_found)
            return
          end
          unless workflow.failed? && workflow.cleaned_up_at.nil?
            render_error("validation_failed", t("api.job_run_commands.errors.workspace_unavailable"), status: :unprocessable_content)
            return
          end

          PushPendingCommitsJob.perform_later(workflow.id)
          render_job(job.reload, message: t("api.job_run_commands.notices.pushing_commits"), changed: [ "workflows" ], workflow: workflow)
        end

        def force_push_branch
          job = @job
          workflow = find_workflow(job)
          return unless workflow

          result = BranchDivergenceRecovery.mark_force_push_pending!(workflow: workflow, user: Current.user)
          unless result.success?
            render_error("validation_failed", result.error, status: :unprocessable_content)
            return
          end

          BranchDivergenceRecoveryJob.perform_later(workflow.id, Current.user.id)
          render_job(job.reload, message: t("api.job_run_commands.notices.replacing_pr_branch"), changed: [ "workflows", "runs", "state" ], workflow: workflow.reload, tab: "workflows")
        end

        def discard_branch_output
          job = @job
          workflow = find_workflow(job)
          return unless workflow

          result = BranchDivergenceRecovery.discard!(workflow: workflow, user: Current.user)
          unless result.success?
            render_error("validation_failed", result.error, status: :unprocessable_content)
            return
          end

          render_job(job.reload, message: t("api.job_run_commands.notices.branch_output_discarded"), changed: [ "workflows", "state" ], workflow: workflow.reload, tab: "workflows")
        end

        def diagnose
          job = @job
          run = job.runs.find_by(id: params[:run_id])
          unless run
            render_error("not_found", t("api.job_run_commands.errors.run_not_found"), status: :not_found)
            return
          end
          unless run.queued? || run.running?
            render_error("validation_failed", t("api.job_run_commands.errors.diagnose_requires_active_run"), status: :unprocessable_content)
            return
          end

          DiagnoseRunJob.set(queue: run.resume_worker_queue || :control_plane).perform_later(run.id)
          render_job(job.reload, message: t("api.job_run_commands.notices.diagnostic_queued"), changed: [ "diagnostics" ], run: run)
        end

        private

        def load_job
          @job = find_job_by_ref(policy_scope(Job).includes(:repository), params[:job_id])
        end

        def authorize_job_command
          authorize_job_mutation!(@job)
        end

        def find_workflow(job)
          workflow = job.workflows.find_by(id: params[:workflow_id])
          unless workflow
            render_error("not_found", t("api.job_run_commands.errors.workflow_not_found"), status: :not_found)
            return nil
          end
          workflow
        end

        def valid_configured_agent_provider?(agent_provider)
          return true if agent_provider.blank?
          return true if Current.user.agent_provider_configured?(agent_provider)

          render_error("validation_failed", t("api.job_run_commands.errors.agent_not_configured"), status: :unprocessable_content)
          false
        end

        def rebase_pull_request_snapshot(job)
          pr_number = job.pr_number || job.external_pr_number
          return if pr_number.blank?

          GithubClient.for(repository: job.repository, user: job.user)
                      .pull_request(job.repository.slug, pr_number, bypass_cache: true)
        rescue StandardError => e
          Rails.logger.info("[App::JobRunCommandsController] failed to load PR ##{pr_number} for rebase #{job.slug}: #{e.class}: #{e.message}")
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
              agent_provider: job.workflow_agent_provider,
              job_provider_setting: job.job_provider_setting,
              provider_availability: ::App::ProviderAvailability.for_user(Current.user, job.workflow_agent_provider),
              pr_number: job.pr_number,
              external_pr_number: job.external_pr_number,
              pr_mergeable: job.pr_mergeable,
              pr_mergeable_checked_at: job.pr_mergeable_checked_at&.iso8601,
              runs_count: job.runs.count,
              workflows_count: job.workflows.count
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
            steps_count: workflow.steps.count,
            runs_count: Run.where(step_id: workflow.steps.select(:id)).count
          }
        end
      end
    end
  end
end
