module Api
  module V1
    module App
      class JobLifecycleController < BaseController
        def start
          job = find_job
          unless job.direct?
            render_error("validation_failed", lifecycle_t("direct_only"), status: :unprocessable_content)
            return
          end
          if job.closed?
            render_error("validation_failed", lifecycle_t("thread_closed"), status: :unprocessable_content)
            return
          end
          if job.backlog?
            render_error("validation_failed", lifecycle_t("backlogged"), status: :unprocessable_content)
            return
          end
          if job.active_runtime_work?
            render_error("validation_failed", lifecycle_t("run_active"), status: :unprocessable_content)
            return
          end
          if job.runs.exists?
            render_error("validation_failed", lifecycle_t("already_started"), status: :unprocessable_content)
            return
          end

          workflow = job.workflows.where(state: "queued", trigger_kind: "initial").order(:created_at).first ||
                     WorkUnits::Launcher.instantiate(kind: "initial", job: job)
          rendered_prompt = Prompts::DirectJob.new(
            prompt: job.issue_body.to_s,
            epic: job.epic,
            job: job,
            user: job.user,
            repository_ids: [ job.repository_id ]
          ).to_s
          result = WorkUnits::Launcher.start!(workflow, prompt: rendered_prompt)
          run = result.run

          if run
            render_job(job.reload, message: lifecycle_t("initial_enqueued"), changed: [ "workflows", "runs" ], tab: "workflows")
          else
            render_error("validation_failed", start_blocked_message(workflow.reload), status: :unprocessable_content)
          end
        end

        def release_from_backlog
          job = find_mutable_job
          return unless authorize_job_mutation!(job)

          unless job.backlog?
            render_error("validation_failed", lifecycle_t("release_backlog_only"), status: :unprocessable_content)
            return
          end
          if job.active_runtime_work?
            render_error("validation_failed", lifecycle_t("run_active"), status: :unprocessable_content)
            return
          end
          unless job.may_release_from_backlog?
            render_error("validation_failed", lifecycle_t("release_unavailable", slug: job.slug, state: job.state), status: :unprocessable_content)
            return
          end

          job.release_from_backlog!
          render_job(job.reload, message: lifecycle_t("released_from_backlog"), changed: [ "state", "workflows", "runs" ], tab: "workflows")
        end

        def move_to_backlog
          job = find_mutable_job
          return unless authorize_job_mutation!(job)

          unless job.may_move_to_backlog?
            render_error("validation_failed", lifecycle_t("move_to_backlog_unavailable", slug: job.slug), status: :unprocessable_content)
            return
          end

          job.move_to_backlog!
          render_job(job.reload, message: lifecycle_t("moved_to_backlog"), changed: [ "state" ])
        end

        # A Job the classifier could not place needs a person to say what it is.
        # Accept means "yes, work on this": the classifier's non-opinion stops
        # mattering and the Job resumes the normal path out of triage.
        def accept_triage
          job = find_mutable_job
          return unless authorize_job_mutation!(job)

          unless job.triaging? && job.triaging_reason_classifier_uncertain?
            render_error("validation_failed", lifecycle_t("not_awaiting_triage", slug: job.slug), status: :unprocessable_content)
            return
          end

          job.accept_triage!
          render_job(job.reload, message: lifecycle_t("accepted"), changed: [ "state", "runs" ])
        end

        # And reject means "no". Closed as `cancelled` rather than one of the
        # successful reasons -- nothing was delivered.
        def reject_triage
          job = find_mutable_job
          return unless authorize_job_mutation!(job)

          unless job.triaging? && job.triaging_reason_classifier_uncertain?
            render_error("validation_failed", lifecycle_t("not_awaiting_triage", slug: job.slug), status: :unprocessable_content)
            return
          end

          job.reject_triage!
          render_job(job.reload, message: lifecycle_t("rejected"), changed: [ "state" ])
        end

        def run_again
          job = find_mutable_job
          return unless authorize_job_mutation!(job)

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

          notice = agent_provider.present? ? lifecycle_t("retry_enqueued_with_provider", provider: agent_provider.titleize) : lifecycle_t("retry_enqueued")
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
              agent_provider: job.workflow_agent_provider,
              job_provider_setting: job.job_provider_setting,
              epic: job.epic
            }

            if job.direct?
              attrs.merge!(
                issue_title: job.issue_title,
                issue_body: job.issue_body
              )
            end

            new_job = Current.user.jobs.create!(attrs)
            new_job.advance_after_triage! if new_job.may_advance_after_triage?

            job.dependent_links.find_each do |dependency|
              dependency.update!(depends_on_job_id: new_job.id)
            end

            broadcast_job_change(job.reload, [ "state" ])
            broadcast_job_change(new_job.reload, [ "created" ])

            render json: job_payload(
              new_job,
              message: lifecycle_t("started_over"),
              tab: nil
            ).merge(
              old_job: job_json(job.reload),
              redirect_to: job_path(new_job)
            ), status: :created
          end
        end

        def cancel
          job = find_mutable_job
          return unless authorize_job_mutation!(job)

          if job.closed?
            render_error("validation_failed", lifecycle_t("already_closed"), status: :unprocessable_content)
            return
          end

          job.cancel_active_runs_and_close!("cancelled")
          render_job(job.reload, message: lifecycle_t("cancellation_requested"), changed: [ "state", "runs" ])
        end

        def stop_landing
          job = find_mutable_job
          return unless authorize_job_mutation!(job)

          unless job.landing?
            render_error("validation_failed", lifecycle_t("not_landing"), status: :unprocessable_content)
            return
          end

          job.stop_landing!
          render_job(job.reload, message: lifecycle_t("landing_stopped"), changed: [ "state", "workflows", "runs" ])
        end

        def force_fail
          unless Current.user.admin?
            render_error("forbidden", I18n.t("api.base.admin_forbidden"), status: :forbidden)
            return
          end

          job = find_job
          unless job.may_force_fail?
            render_error("validation_failed", lifecycle_t("force_fail_unavailable", slug: job.slug, state: job.state), status: :unprocessable_content)
            return
          end

          job.force_fail!
          render_job(job.reload, message: lifecycle_t("force_failed"), changed: [ "state" ])
        end

        def approve
          job = find_mutable_job
          return unless authorize_job_mutation!(job)

          unless job.auto_merge_enabled?
            render_error("validation_failed", lifecycle_t("auto_merge_disabled", slug: job.repository.slug), status: :unprocessable_content)
            return
          end
          unless job.can_add_job_approval?(Current.user)
            render_error("validation_failed", lifecycle_t("approval_forbidden"), status: :unprocessable_content)
            return
          end

          approval = job.job_approvals.find_or_initialize_by(user: Current.user)
          approval.approved_at ||= Time.current
          approval.save!

          if job.approval_satisfied? && job.may_approve?
            job.approve!(via: "operator", by_user: Current.user)
            github_note = Job::ApprovalPropagator.approve(job, user: Current.user).message
            landing_workflow = LandingQueueProcessor.try_land!(job)
            landing_note = landing_workflow ? lifecycle_t("landing_enqueued") : nil
            changed = landing_workflow ? [ "state", "approval", "workflows", "runs" ] : [ "state", "approval" ]
            render_job(job.reload, message: [ lifecycle_t("approved"), github_note, landing_note ].compact.join(" "), changed: changed)
          else
            render_job(job.reload, message: lifecycle_t("approval_recorded"), changed: [ "approval" ])
          end
        end

        def unapprove
          job = find_job
          unless job.may_unapprove?
            render_error("validation_failed", lifecycle_t("unapprove_unavailable"), status: :unprocessable_content)
            return
          end

          github_note = Job::ApprovalUnapprover.call(job: job, user: Current.user).message
          render_job(job.reload, message: [ lifecycle_t("unapproved"), github_note ].compact.join(" "), changed: [ "state", "approval" ])
        end

        def reopen
          job = find_job
          unless job.may_reopen?
            render_error("validation_failed", lifecycle_t("not_closed"), status: :unprocessable_content)
            return
          end

          prior_reason = job.closure_reason
          job.reopen!
          job.save!
          render_job(job.reload, message: reopen_notice(prior_reason), changed: [ "state" ])
        end

        def pause
          job = find_job
          if job.closed?
            render_error("validation_failed", lifecycle_t("pause_closed"), status: :unprocessable_content)
            return
          end
          if job.manual_paused?
            render_job(job.reload, message: lifecycle_t("already_paused"), changed: [ "manual_pause" ])
            return
          end

          JobManualPause.pause!(job, by_user: Current.user)
          render_job(job.reload, message: lifecycle_t("paused"), changed: [ "manual_pause" ])
        end

        def unpause
          job = find_job
          unless job.manual_paused?
            render_job(job.reload, message: lifecycle_t("not_paused"), changed: [ "manual_pause" ])
            return
          end

          JobManualPause.unpause!(job)
          render_job(job.reload, message: lifecycle_t("unpaused"), changed: [ "manual_pause", "workflows", "runs" ])
        end

        def open_in_local_mode
          unless Feature.local_mode_enabled?
            render_error("forbidden", lifecycle_t("local_mode_disabled"), status: :forbidden)
            return
          end

          job = find_job
          unless job.implemented? || job.approved?
            render_error("validation_failed", lifecycle_t("local_mode_state_unavailable"), status: :unprocessable_content)
            return
          end
          if job.linked_chat_id.present?
            render_error("validation_failed", lifecycle_t("local_mode_already_linked"), status: :unprocessable_content)
            return
          end

          chat_id = params[:chat_id].presence
          chat = if chat_id
            Current.user.accessible_chat_sessions.find_by(id: chat_id, mode: "local")
          else
            Current.user.accessible_chat_sessions.where(mode: "local").order(updated_at: :desc).first
          end

          unless chat
            render_error("validation_failed", lifecycle_t("local_mode_chat_missing"), status: :unprocessable_content)
            return
          end

          ApplicationRecord.transaction do
            if job.approved?
              Job::ApprovalUnapprover.call(job: job, user: Current.user)
            end
            job.linked_chat_id = chat.id
            job.enter_local_mode!
            job.save!
          end

          render_job(job.reload, message: lifecycle_t("local_mode_opened"), changed: [ "state" ])
        end

        def cancel_local_mode
          unless Feature.local_mode_enabled?
            render_error("forbidden", lifecycle_t("local_mode_disabled"), status: :forbidden)
            return
          end

          job = find_job
          unless job.coding?
            render_error("validation_failed", lifecycle_t("not_coding"), status: :unprocessable_content)
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

          render_job(job.reload, message: lifecycle_t("local_mode_cancelled"), changed: [ "state" ])
        end

        private

        def find_job
          find_job_by_ref(Current.user.jobs.includes(:repository), params[:job_id])
        end

        # approve/run_again/cancel resolve through the wider,
        # repository-membership-based JobPolicy::Scope (find_job's
        # Current.user.jobs stays creator-only for the other actions in
        # this controller) so a write-tier repository member can reach
        # them; authorize_job_mutation! (BaseController) still gates the
        # actual mutation.
        def find_mutable_job
          find_job_by_ref(policy_scope(Job).includes(:repository), params[:job_id])
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
            actions: ::App::JobDetailPayload.actions_payload(job: job, user: Current.user)[:actions],
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
              agent_provider: job.workflow_agent_provider,
              job_provider_setting: job.job_provider_setting,
              provider_availability: ::App::ProviderAvailability.for_user(Current.user, job.workflow_agent_provider),
            approved_at: job.approved_at&.iso8601,
            approved_via: job.approved_via,
            approved_by_user_id: job.approved_by_user_id,
            runs_count: job.runs.count,
            workflows_count: job.workflows.count
          }
        end

        def start_blocked_message(workflow)
          reason = WorkUnits::StartBlock.for(workflow).reason || workflow.artifact("start_cancelled_reason")
          if reason.present?
            lifecycle_t("start_blocked", reason: display_start_blocked_reason(reason))
          else
            lifecycle_t("start_blocked_unknown")
          end
        end

        def display_start_blocked_reason(reason)
          case reason.to_s
          when "admission_control", StepDispatcher::ADMISSION_BLOCK_REASON
            lifecycle_t("blocked_reasons.admission_control")
          else
            reason.to_s.tr("_", " ")
          end
        end

        def reopen_notice(prior_reason)
          base = lifecycle_t("reopened")
          case prior_reason
          when "syrus_stop"
            "#{base} #{lifecycle_t('reopened_syrus_stop')}"
          when "pr_merged", "pr_closed"
            "#{base} #{lifecycle_t('reopened_pr_state')}"
          else
            base
          end
        end

        def lifecycle_t(key, **options)
          I18n.t("api.job_lifecycle.#{key}", **options)
        end
      end
    end
  end
end
