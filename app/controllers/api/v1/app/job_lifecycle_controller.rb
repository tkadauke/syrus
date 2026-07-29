module Api
  module V1
    module App
      class JobLifecycleController < BaseController
        def start
          job = find_job
          unless job.direct?
            render_error("validation_failed", "Only direct Jobs can be started manually.", status: :unprocessable_content)
            return
          end
          if job.closed?
            render_error("validation_failed", "Thread is closed - reopen it before starting work.", status: :unprocessable_content)
            return
          end
          if job.any_active_run?
            render_error("validation_failed", "A Run is already in progress - wait for it to finish.", status: :unprocessable_content)
            return
          end
          if job.runs.exists?
            render_error("validation_failed", "This Job has already been started - use Retry instead.", status: :unprocessable_content)
            return
          end

          workflow = job.workflows.where(state: "queued", trigger_kind: "initial").order(:created_at).first ||
                     Workflows::Initial.instantiate(job: job, agent_provider: job.agent_provider)
          rendered_prompt = Prompts::DirectJob.new(
            prompt: job.issue_body.to_s,
            epic: job.epic,
            job: job,
            user: job.user,
            repository_ids: [ job.repository_id ]
          ).to_s
          StepDispatcher.start_workflow(workflow, prompt: rendered_prompt)

          render_job(job.reload, message: "Initial workflow enqueued.", changed: [ "workflows", "runs" ], tab: "workflows")
        end

        def run_again
          job = find_job
          ctx = params[:retry_context].presence || params[:replay_context]
          ctx = ctx.to_s.strip
          artifacts = ctx.present? ? { "replay_context" => ctx } : nil
          agent_provider = params[:agent_provider].to_s.presence

          result = RetryWorkflowEnqueuer.call(
            job: job,
            artifacts: artifacts,
            agent_provider: agent_provider,
            provider_validation: :retry_alternate
          )
          unless result.success?
            render_error("validation_failed", result.error, status: :unprocessable_content)
            return
          end

          notice = agent_provider.present? ? "Retry workflow enqueued with #{agent_provider.titleize}." : "Retry workflow enqueued."
          render_job(job.reload, message: notice, changed: [ "workflows", "runs" ], tab: "workflows")
        end

        def restart
          job = find_job
          ApplicationRecord.transaction do
            job.cancel_active_runs_and_close!("replaced") if job.open?
            skip_prepare = job.sync_skip_prepare_from_source!

            attrs = {
              repository: job.repository,
              issue_number: job.issue_number,
              skip_prepare: skip_prepare,
              kind: job.kind,
              agent_provider: job.agent_provider
            }

            if job.direct?
              attrs.merge!(
                issue_title: job.issue_title,
                issue_body: job.issue_body,
                epic: job.epic
              )
            end

            new_job = Current.user.jobs.create!(attrs)
            new_job.advance_after_triage! if new_job.may_advance_after_triage?

            broadcast_job_change(job.reload, [ "state" ])
            broadcast_job_change(new_job.reload, [ "created" ])

            render json: job_payload(
              new_job,
              message: "Started over - new branch and PR will be created.",
              tab: nil
            ).merge(
              old_job: job_json(job.reload),
              redirect_to: job_path(new_job)
            ), status: :created
          end
        end

        def cancel
          job = find_job
          if job.closed?
            render_error("validation_failed", "Job is already closed.", status: :unprocessable_content)
            return
          end

          job.cancel_active_runs_and_close!("cancelled")
          render_job(job.reload, message: "Cancellation requested.", changed: [ "state", "runs" ])
        end

        def approve
          job = find_job
          unless job.repository.auto_merge_enabled?
            render_error("validation_failed", "Auto-merge is disabled for #{job.repository.slug}; enable it in repository settings before approving.", status: :unprocessable_content)
            return
          end
          unless job.can_add_job_approval?(Current.user)
            render_error("validation_failed", "Only the job owner or other repository members can add approval — the job creator cannot approve unless they are also the owner.", status: :unprocessable_content)
            return
          end

          approval = job.job_approvals.find_or_initialize_by(user: Current.user)
          approval.approved_at ||= Time.current
          approval.save!

          if job.approval_satisfied? && job.may_approve?
            job.approve!(via: "operator", by_user: Current.user)
            github_note = Job::ApprovalPropagator.approve(job, user: Current.user).message
            landing_workflow = LandingQueueProcessor.try_land!(job)
            landing_note = landing_workflow ? "Landing workflow enqueued." : nil
            changed = landing_workflow ? [ "state", "approval", "workflows", "runs" ] : [ "state", "approval" ]
            render_job(job.reload, message: [ "Job approved.", github_note, landing_note ].compact.join(" "), changed: changed)
          else
            render_job(job.reload, message: "Approval recorded.", changed: [ "approval" ])
          end
        end

        def unapprove
          job = find_job
          unless job.may_unapprove?
            render_error("validation_failed", "Only approved Jobs that have not started landing can be unapproved.", status: :unprocessable_content)
            return
          end

          review_id = job.approval_evidence&.dig("github_review_id")
          job.unapprove!
          github_note = Job::ApprovalPropagator.dismiss(job, review_id, user: Current.user).message
          render_job(job.reload, message: [ "Job unapproved.", github_note ].compact.join(" "), changed: [ "state", "approval" ])
        end

        def reopen
          job = find_job
          unless job.may_reopen?
            render_error("validation_failed", "Job isn't closed.", status: :unprocessable_content)
            return
          end

          prior_reason = job.closure_reason
          job.reopen!
          job.save!
          render_job(job.reload, message: reopen_notice(prior_reason), changed: [ "state" ])
        end

        def open_in_local_mode
          unless Feature.local_mode_enabled?
            render_error("forbidden", "Local mode is not enabled.", status: :forbidden)
            return
          end

          job = find_job
          unless job.implemented? || job.approved?
            render_error("validation_failed", "Only implemented or approved Jobs can be opened in local mode.", status: :unprocessable_content)
            return
          end
          if job.linked_chat_id.present?
            render_error("validation_failed", "Job is already linked to a local coding session.", status: :unprocessable_content)
            return
          end

          chat_id = params[:chat_id].presence
          chat = if chat_id
            Current.user.chat_sessions.find_by(id: chat_id, mode: "local")
          else
            Current.user.chat_sessions.where(mode: "local").order(updated_at: :desc).first
          end

          unless chat
            render_error("validation_failed", "No active Local Mode chat found. Start a chat in Local Mode first.", status: :unprocessable_content)
            return
          end

          ApplicationRecord.transaction do
            if job.approved?
              review_id = job.approval_evidence&.dig("github_review_id")
              job.unapprove!
              Job::ApprovalPropagator.dismiss(job, review_id, user: Current.user)
            end
            job.linked_chat_id = chat.id
            job.enter_local_mode!
            job.save!
          end

          render_job(job.reload, message: "Job opened in local mode. Continue in the linked chat.", changed: [ "state" ])
        end

        def cancel_local_mode
          unless Feature.local_mode_enabled?
            render_error("forbidden", "Local mode is not enabled.", status: :forbidden)
            return
          end

          job = find_job
          unless job.coding?
            render_error("validation_failed", "Job is not in coding state.", status: :unprocessable_content)
            return
          end

          ApplicationRecord.transaction do
            job.linked_chat_id = nil
            if job.pr_number.present?
              job.exit_local_mode!
              job.save!
            else
              job.save!
              job.cancel_active_runs_and_close!("local_mode_cancelled")
            end
          end

          render_job(job.reload, message: "Local mode session cancelled.", changed: [ "state" ])
        end

        private

        def find_job
          find_job_by_ref(Current.user.jobs.includes(:repository, :runs, :workflows), params[:job_id])
        end

        def render_job(job, message:, changed:, tab: nil)
          broadcast_job_change(job, changed)
          render json: job_payload(job, message: message, tab: tab)
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
            job: job_json(job),
            paths: {
              job_path: tab ? job_path(job, tab: tab) : job_path(job)
            }
          }
        end

        def job_json(job)
          {
            id: job.id,
            state: job.state,
            closure_reason: job.closure_reason,
            approved_at: job.approved_at&.iso8601,
            approved_via: job.approved_via,
            approved_by_user_id: job.approved_by_user_id,
            runs_count: job.runs.size,
            workflows_count: job.workflows.size
          }
        end

        def reopen_notice(prior_reason)
          base = "Thread reopened."
          case prior_reason
          when "syrus_stop"
            "#{base} Heads up: the next poll will re-close it if the syrus-stop label is still on the PR."
          when "pr_merged", "pr_closed"
            "#{base} Heads up: the next poll will check the PR state and may re-close it."
          else
            base
          end
        end
      end
    end
  end
end
