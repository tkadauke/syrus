module Api
  module V1
    module App
      class DashboardController < BaseController
        def show
          render json: ::App::DashboardPayload.call(user: Current.user, params: params)
        rescue ::App::DashboardPayload::InvalidScope => e
          render_error("validation_failed", e.message, status: :unprocessable_content)
        end

        def preferences
          subject = params.require(:subject)

          if params.key?(:sort_column) || params.key?(:sort_direction)
            if params.key?(:active_smart_folder_id)
              Current.user.update_dashboard_folder_preferences!(
                subject: subject,
                smart_folder_id: params[:active_smart_folder_id],
                sort_column: params.require(:sort_column),
                sort_direction: params.require(:sort_direction)
              )
            else
              Current.user.update_dashboard_sort!(
                subject: subject,
                column: params.require(:sort_column),
                direction: params.require(:sort_direction)
              )
            end
          end

          if params.key?(:visible_columns)
            Current.user.update_dashboard_columns!(
              subject: subject,
              columns: params[:visible_columns]
            )
          end

          if params.key?(:kanban_lanes)
            Current.user.update_dashboard_kanban_lanes!(
              subject: subject,
              lanes: params[:kanban_lanes]
            )
          end

          if params.key?(:view)
            if params.key?(:active_smart_folder_id)
              Current.user.update_dashboard_folder_preferences!(
                subject: subject,
                smart_folder_id: params[:active_smart_folder_id],
                view: params[:view]
              )
            else
              Current.user.update_dashboard_view!(
                subject: subject,
                view: params[:view]
              )
            end
          end

          if params.key?(:smart_folder_id)
            Current.user.update_dashboard_smart_folder!(
              subject: subject,
              smart_folder_id: params[:smart_folder_id]
            )
          end

          render json: {
            message: dashboard_t("preferences_updated"),
            dashboard_preferences: Current.user.reload.dashboard_preferences
          }
        rescue ActionController::ParameterMissing, ArgumentError => e
          render_error("validation_failed", e.message, status: :unprocessable_content)
        end

        def landing_pause
          pausing = !Current.user.landing_paused?
          if pausing && !ActiveModel::Type::Boolean.new.cast(params[:confirmed])
            render_error("confirmation_required", dashboard_t("confirm_landing_pause"), status: :unprocessable_content)
            return
          end

          Current.user.update!(landing_paused: pausing)
          LandingQueueProcessorJob.perform_later unless Current.user.landing_paused?

          render json: {
            message: dashboard_t(Current.user.landing_paused? ? "landing_paused" : "landing_resumed"),
            landing_paused: Current.user.landing_paused?
          }
        end

        def bulk_jobs
          job_ids = Array(params[:job_ids]).filter_map { |id| Integer(id, exception: false) }.uniq
          if job_ids.empty?
            render_error("validation_failed", dashboard_t("select_job"), status: :unprocessable_content)
            return
          end

          jobs = bulk_job_scope(job_ids)

          case params[:bulk_action].to_s
          when "retry"
            bulk_retry_jobs(jobs)
          when /\Aretry:(.+)\z/
            bulk_retry_jobs(jobs, agent_provider: Regexp.last_match(1))
          when "close"
            bulk_close_jobs(jobs)
          when "approve"
            bulk_approve_jobs(jobs)
          when "accept_triage"
            bulk_accept_triage(jobs)
          when "claim"
            bulk_claim_jobs(jobs)
          when "release_claim"
            bulk_release_claims(jobs)
          when "release_from_backlog", "start"
            bulk_release_backlogged_jobs(jobs)
          when "move_to_backlog"
            bulk_move_jobs_to_backlog(jobs)
          when "assign_owner"
            bulk_assign_owner(jobs)
          when "set_priority"
            bulk_set_priority(jobs)
          when "pause"
            bulk_pause_jobs(jobs)
          when "unpause"
            bulk_unpause_jobs(jobs)
          when "review_approve"
            bulk_review_approval(jobs)
          when "commit_review_approval"
            bulk_commit_review_approval(jobs)
          when "apply_tag"
            bulk_apply_tag(jobs)
          else
            render_error("validation_failed", dashboard_t("choose_bulk_action"), status: :unprocessable_content)
          end
        end

        def bulk_epics
          epic_ids = Array(params[:epic_ids]).filter_map { |id| Integer(id, exception: false) }.uniq
          if epic_ids.empty?
            render_error("validation_failed", dashboard_t("select_epic"), status: :unprocessable_content)
            return
          end

          epics = bulk_epic_scope(epic_ids)

          case params[:bulk_action].to_s
          when "start"
            bulk_start_epics(epics)
          else
            render_error("validation_failed", dashboard_t("choose_bulk_action"), status: :unprocessable_content)
          end
        end

        def epic_auto_approval
          epic = accessible_epics.find(params[:id])
          unless RepositoryPolicy.new(Current.user, epic.repository).write?
            render_error("forbidden", dashboard_t("epic_auto_approval_forbidden"), status: :forbidden)
            return
          end
          epic.update!(params.expect(epic: [ :auto_approve_mode ]))

          render json: {
            message: dashboard_t("epic_auto_approval_updated"),
            epic: {
              id: epic.id,
              auto_approve_mode: epic.auto_approve_mode
            }
          }
        rescue ActiveRecord::RecordInvalid => e
          render_error("validation_failed", e.record.errors.full_messages.to_sentence, status: :unprocessable_content)
        end

        private

        def bulk_job_scope(job_ids)
          policy_scope(Job).joins(:repository)
                           .where(repositories: { archived_at: nil })
                           .where(id: job_ids)
                           .includes(:repository, :owner_user, :claimed_by_user)
        end

        def bulk_epic_scope(epic_ids)
          accessible_epics.joins(:repository)
                           .where(repositories: { archived_at: nil })
                           .where(id: epic_ids)
                           .includes(:repository)
        end

        def accessible_epics
          scope = Current.user.admin? ? Epic.all : policy_scope(Epic)
          restrict_invocation_relation(scope)
        end

        def bulk_retry_jobs(jobs, agent_provider: nil)
          if agent_provider.present? && !Current.user.agent_provider_configured?(agent_provider)
            render_error("validation_failed", dashboard_t("retry_agent_unavailable"), status: :unprocessable_content)
            return
          end

          result = SmartRetryEnqueuer.call_many(
            jobs: writable_jobs(jobs).to_a,
            agent_provider: agent_provider,
            automatic: true,
            by_user: Current.user
          )

          if result.affected_job_ids.empty?
            render_error("validation_failed", dashboard_t("none_retryable"), status: :unprocessable_content)
          else
            message_key = agent_provider.present? ? "retry_enqueued_with_agent" : "retry_enqueued"
            message = dashboard_t(message_key, count: result.affected_job_ids.size, agent: agent_provider&.titleize)
            render_bulk_success(
              bulk_partial_message(message, result.skipped.map { |skipped| skipped.job.id }),
              affected_job_ids: result.affected_job_ids,
              skipped_job_ids: result.skipped.map { |skipped| skipped.job.id },
              action: "retry",
              extra: {
                retry_summary: {
                  actions: result.action_summary,
                  skipped: result.skip_summary
                }
              }
            )
          end
        end

        def bulk_close_jobs(jobs)
          closed_ids = []
          skipped_ids = []
          jobs.find_each do |job|
            unless JobPolicy.new(Current.user, job).write? && !job.closed?
              skipped_ids << job.id
              next
            end

            job.cancel_active_runs_and_close!("cancelled")
            closed_ids << job.id
          end

          if closed_ids.empty?
            render_error("validation_failed", dashboard_t("none_open"), status: :unprocessable_content)
          else
            render_bulk_success(
              bulk_partial_message(dashboard_t("jobs_closed", count: closed_ids.size), skipped_ids),
              affected_job_ids: closed_ids,
              skipped_job_ids: skipped_ids,
              action: "close"
            )
          end
        end

        def bulk_approve_jobs(jobs)
          batch_id = SecureRandom.uuid
          skipped_auto_merge_disabled = []
          skipped_ids = []
          eligible_jobs = []

          jobs.each do |job|
            unless JobPolicy.new(Current.user, job).write?
              skipped_ids << job.id
              next
            end

            unless job.auto_merge_enabled?
              skipped_auto_merge_disabled << job
              next
            end

            eligible_jobs << job
          end

          result = Jobs::BulkApprover.call(
            eligible_jobs,
            via: "bulk",
            by_user: Current.user,
            evidence: { "batch_id" => batch_id }
          )
          approved_jobs = result.approved
          skipped_ids += result.failed.map(&:id)

          if approved_jobs.empty? && skipped_auto_merge_disabled.empty?
            render_error("validation_failed", dashboard_t("none_awaiting_approval"), status: :unprocessable_content)
          elsif approved_jobs.empty?
            render_error("validation_failed", bulk_auto_merge_disabled_message(skipped_auto_merge_disabled), status: :unprocessable_content)
          else
            github_note = bulk_github_approval_note(approved_jobs)
            skip_note = skipped_auto_merge_disabled.any? ? bulk_auto_merge_disabled_message(skipped_auto_merge_disabled) : nil
            render_bulk_success(
              [ dashboard_t("jobs_approved", count: approved_jobs.size, batch_id: batch_id), github_note, skip_note ].compact.join(" "),
              affected_job_ids: approved_jobs.map(&:id),
              skipped_job_ids: (skipped_auto_merge_disabled.map(&:id) + skipped_ids).uniq,
              action: "approve",
              extra: { batch_id: batch_id }
            )
          end
        end

        def bulk_accept_triage(jobs)
          accepted_ids = []
          skipped_ids = []

          jobs.find_each do |job|
            unless JobPolicy.new(Current.user, job).write? && job.awaiting_triage_decision? && !job.triaging_reason_placement_confirmation?
              skipped_ids << job.id
              next
            end

            job.accept_triage!
            accepted_ids << job.id
          end

          if accepted_ids.empty?
            render_error("validation_failed", dashboard_t("none_awaiting_triage"), status: :unprocessable_content)
          else
            render_bulk_success(
              bulk_partial_message(dashboard_t("jobs_accepted", count: accepted_ids.size), skipped_ids),
              affected_job_ids: accepted_ids,
              skipped_job_ids: skipped_ids,
              action: "accept_triage"
            )
          end
        end

        def bulk_claim_jobs(jobs)
          claimed_ids = []
          skipped_ids = []
          jobs.find_each do |job|
            unless JobPolicy.new(Current.user, job).write? && (job.claimed_by_user_id.blank? || job.claimed_by_user_id == Current.user.id)
              skipped_ids << job.id
              next
            end

            job.update!(claimed_by_user: Current.user, claimed_at: Time.current)
            claimed_ids << job.id
          end

          if claimed_ids.empty?
            render_error("validation_failed", dashboard_t("none_claimable"), status: :unprocessable_content)
          else
            render_bulk_success(
              bulk_partial_message(dashboard_t("jobs_claimed", count: claimed_ids.size), skipped_ids),
              affected_job_ids: claimed_ids,
              skipped_job_ids: skipped_ids,
              action: "claim"
            )
          end
        end

        def bulk_release_claims(jobs)
          released_ids = []
          skipped_ids = []
          jobs.find_each do |job|
            unless JobPolicy.new(Current.user, job).write? && job.claimed_by_user_id == Current.user.id
              skipped_ids << job.id
              next
            end

            job.update!(claimed_by_user: nil, claimed_at: nil)
            released_ids << job.id
          end

          if released_ids.empty?
            render_error("validation_failed", dashboard_t("none_claimed_by_you"), status: :unprocessable_content)
          else
            render_bulk_success(
              bulk_partial_message(dashboard_t("claims_released", count: released_ids.size), skipped_ids),
              affected_job_ids: released_ids,
              skipped_job_ids: skipped_ids,
              action: "release_claim"
            )
          end
        end

        def bulk_release_backlogged_jobs(jobs)
          released_ids = []
          skipped_ids = []

          jobs.find_each do |job|
            unless JobPolicy.new(Current.user, job).write? && job.backlog? && !job.active_runtime_work? && job.may_release_from_backlog?
              skipped_ids << job.id
              next
            end

            job.release_from_backlog!
            released_ids << job.id
          end

          if released_ids.empty?
            render_error("validation_failed", dashboard_t("none_backlogged_startable"), status: :unprocessable_content)
          else
            render_bulk_success(
              bulk_partial_message(dashboard_t("jobs_released_from_backlog", count: released_ids.size), skipped_ids),
              affected_job_ids: released_ids,
              skipped_job_ids: skipped_ids,
              action: "release_from_backlog"
            )
          end
        end

        def bulk_move_jobs_to_backlog(jobs)
          moved_ids = []
          skipped_ids = []

          jobs.find_each do |job|
            unless JobPolicy.new(Current.user, job).write? && job.may_move_to_backlog?
              skipped_ids << job.id
              next
            end

            job.move_to_backlog!
            moved_ids << job.id
          end

          if moved_ids.empty?
            render_error("validation_failed", dashboard_t("none_movable_to_backlog"), status: :unprocessable_content)
          else
            render_bulk_success(
              bulk_partial_message(dashboard_t("jobs_moved_to_backlog", count: moved_ids.size), skipped_ids),
              affected_job_ids: moved_ids,
              skipped_job_ids: skipped_ids,
              action: "move_to_backlog"
            )
          end
        end

        def bulk_assign_owner(jobs)
          owner = find_bulk_owner
          return unless owner

          assigned_ids = []
          skipped_ids = []

          jobs.find_each do |job|
            unless JobPolicy.new(Current.user, job).write? && job.repository.member_at_least?(owner, "read")
              skipped_ids << job.id
              next
            end

            job.update!(owner_user: owner)
            assigned_ids << job.id
          end

          if assigned_ids.empty?
            render_error("validation_failed", dashboard_t("none_assignable"), status: :unprocessable_content)
          else
            render_bulk_success(
              bulk_partial_message(dashboard_t("jobs_assigned", count: assigned_ids.size, owner: owner.email_address), skipped_ids),
              affected_job_ids: assigned_ids,
              skipped_job_ids: skipped_ids,
              action: "assign_owner",
              extra: { owner_user: owner_user_json(owner) }
            )
          end
        end

        def bulk_set_priority(jobs)
          priority = params[:priority].to_s
          unless Job::PRIORITIES.include?(priority)
            render_error("invalid_priority", dashboard_t("invalid_priority"), status: :unprocessable_content)
            return
          end

          updated_ids = []
          skipped_ids = []
          jobs.find_each do |job|
            unless JobPolicy.new(Current.user, job).write?
              skipped_ids << job.id
              next
            end

            job.update!(priority: priority)
            updated_ids << job.id
          end

          if updated_ids.empty?
            render_error("validation_failed", dashboard_t("none_updatable"), status: :unprocessable_content)
          else
            render_bulk_success(
              bulk_partial_message(dashboard_t("jobs_priority_set", count: updated_ids.size, priority: priority), skipped_ids),
              affected_job_ids: updated_ids,
              skipped_job_ids: skipped_ids,
              action: "set_priority",
              extra: { priority: priority }
            )
          end
        end

        def find_bulk_owner
          owner_user_id = params[:owner_user_id].presence || params.dig(:job, :owner_user_id).presence
          unless owner_user_id
            render_error("validation_failed", dashboard_t("choose_owner"), status: :unprocessable_content)
            return nil
          end

          User.find_by(id: owner_user_id).tap do |owner|
            render_error("not_found", dashboard_t("owner_not_found"), status: :not_found) unless owner
          end
        end

        def owner_user_json(owner)
          {
            id: owner.id,
            email_address: owner.email_address,
            display_name: owner.display_name,
            profile_path: profile_path(owner)
          }
        end

        def bulk_partial_message(message, skipped_ids)
          return message if skipped_ids.empty?

          "#{message} #{dashboard_t('jobs_skipped', count: skipped_ids.size)}"
        end

        def bulk_pause_jobs(jobs)
          paused_ids = []
          skipped_ids = []
          jobs.find_each do |job|
            unless JobPolicy.new(Current.user, job).write? && job.open? && !job.manual_paused?
              skipped_ids << job.id
              next
            end

            JobManualPause.pause!(job, by_user: Current.user)
            paused_ids << job.id
          end

          if paused_ids.empty?
            render_error("validation_failed", dashboard_t("none_pausable"), status: :unprocessable_content)
          else
            render_bulk_success(
              bulk_partial_message(dashboard_t("jobs_paused", count: paused_ids.size), skipped_ids),
              affected_job_ids: paused_ids,
              skipped_job_ids: skipped_ids,
              action: "pause"
            )
          end
        end

        def bulk_unpause_jobs(jobs)
          unpaused_ids = []
          skipped_ids = []
          jobs.find_each do |job|
            unless JobPolicy.new(Current.user, job).write? && job.open? && job.manual_paused?
              skipped_ids << job.id
              next
            end

            JobManualPause.unpause!(job)
            unpaused_ids << job.id
          end

          if unpaused_ids.empty?
            render_error("validation_failed", dashboard_t("none_unpausable"), status: :unprocessable_content)
          else
            render_bulk_success(
              bulk_partial_message(dashboard_t("jobs_unpaused", count: unpaused_ids.size), skipped_ids),
              affected_job_ids: unpaused_ids,
              skipped_job_ids: skipped_ids,
              action: "unpause"
            )
          end
        end

        def bulk_review_approval(jobs)
          review_jobs = writable_jobs(jobs)
            .select(&:implemented?)
            .sort_by { |job| [ job.created_at || Time.zone.at(0), job.id ] }
            .reverse
          if review_jobs.empty?
            render_error("validation_failed", dashboard_t("none_awaiting_approval"), status: :unprocessable_content)
            return
          end

          render json: {
            message: dashboard_t("review_selected"),
            action: "review_approve",
            review_jobs: review_jobs.map { |job| review_job_json(job) }
          }
        end

        def bulk_commit_review_approval(jobs)
          choices_param = params[:approval_choices]
          choices = choices_param.respond_to?(:to_unsafe_h) ? choices_param.to_unsafe_h : {}
          ids_to_approve = choices.select { |_id, choice| choice == "approve" }.keys
          reviewed_jobs = writable_jobs(jobs).select { |job| ids_to_approve.include?(job.id.to_s) && job.implemented? }

          if reviewed_jobs.empty?
            render_error("validation_failed", dashboard_t("none_reviewed_approved"), status: :unprocessable_content)
            return
          end

          batch_id = SecureRandom.uuid
          result = Jobs::BulkApprover.call(
            reviewed_jobs,
            via: "bulk",
            by_user: Current.user,
            evidence: { "batch_id" => batch_id }
          )
          approved_jobs = result.approved

          if approved_jobs.empty?
            render_error("validation_failed", dashboard_t("none_reviewed_approved"), status: :unprocessable_content)
            return
          end

          github_note = bulk_github_approval_note(approved_jobs)
          render_bulk_success(
            [ dashboard_t("jobs_approved", count: approved_jobs.size, batch_id: batch_id), github_note ].compact.join(" "),
            affected_job_ids: approved_jobs.map(&:id),
            action: "commit_review_approval",
            extra: { batch_id: batch_id }
          )
        end

        def bulk_apply_tag(jobs)
          tag = find_or_create_bulk_tag
          return unless tag

          applied_ids = []
          skipped_ids = []
          jobs.find_each do |job|
            unless JobPolicy.new(Current.user, job).write?
              skipped_ids << job.id
              next
            end

            job.job_tags.find_or_create_by!(tag: tag)
            applied_ids << job.id
          end

          if applied_ids.empty?
            render_error("validation_failed", dashboard_t("none_taggable"), status: :unprocessable_content)
            return
          end

          render_bulk_success(
            bulk_partial_message(dashboard_t("tag_applied", count: applied_ids.size, tag: tag.name), skipped_ids),
            affected_job_ids: applied_ids,
            skipped_job_ids: skipped_ids,
            action: "apply_tag",
            extra: { tag: { id: tag.id, name: tag.name, color: tag.color } }
          )
        end

        def find_or_create_bulk_tag
          if params[:tag_id].present?
            tag = Current.user.tags.find_by(id: params[:tag_id])
            unless tag
              render_error("not_found", dashboard_t("tag_not_found"), status: :not_found)
              return nil
            end
            return tag
          end

          name = params[:tag_name].to_s.strip
          if name.blank?
            render_error("validation_failed", dashboard_t("choose_tag"), status: :unprocessable_content)
            return nil
          end

          Current.user.tags.find_or_create_by!(name: name) { |tag| tag.color = "gray" }
        end

        def writable_jobs(jobs)
          jobs.select { |job| JobPolicy.new(Current.user, job).write? }
        end

        def bulk_start_epics(epics)
          if Current.user.product_owner?
            render_error("forbidden", dashboard_t("product_owner_epic_start_forbidden"), status: :forbidden)
            return
          end

          started_ids = []
          skipped_ids = []

          epics.find_each do |epic|
            if RepositoryPolicy.new(Current.user, epic.repository).write? && epic.ready? && epic.may_start?(actor: Current.user)
              epic.start!(actor: Current.user)
              started_ids << epic.id
            else
              skipped_ids << epic.id
            end
          end

          if started_ids.empty?
            render_error("validation_failed", dashboard_t("none_epics_ready"), status: :unprocessable_content)
          else
            render_epic_bulk_success(
              dashboard_t("epics_started", count: started_ids.size),
              affected_epic_ids: started_ids,
              skipped_epic_ids: skipped_ids,
              action: "start"
            )
          end
        end

        def bulk_auto_merge_disabled_message(skipped)
          repos = skipped.map { |job| job.repository.slug }.uniq.sort
          dashboard_t("auto_merge_disabled", count: skipped.size, repositories: repos.join(", "))
        end

        def bulk_github_approval_note(jobs)
          results = jobs.map { |job| Job::ApprovalPropagator.approve(job, user: Current.user) }
          successes = results.count(&:success?)
          failures = results.select(&:failure?)
          notes = []
          notes << dashboard_t("github_reviews_left", count: successes) if successes.positive?
          notes << failures.map(&:message).uniq.join(" ") if failures.any?
          notes.presence&.join(" ")
        end

        def render_bulk_success(message, affected_job_ids:, action:, skipped_job_ids: [], extra: {})
          AppEvents.broadcast(
            user: Current.user,
            type: "updated",
            resource: "job",
            id: nil,
            changed: [ "bulk" ],
            payload: { "action" => action, "affected_job_ids" => affected_job_ids }
          )

          render json: {
            message: message,
            action: action,
            affected_job_ids: affected_job_ids,
            skipped_job_ids: skipped_job_ids
          }.merge(extra)
        end

        def dashboard_t(key, **options)
          t("api.dashboard.#{key}", **options)
        end

        def render_epic_bulk_success(message, affected_epic_ids:, action:, skipped_epic_ids: [], extra: {})
          AppEvents.broadcast(
            user: Current.user,
            type: "updated",
            resource: "epic",
            id: nil,
            changed: [ "bulk" ],
            payload: { "action" => action, "affected_epic_ids" => affected_epic_ids }
          )

          render json: {
            message: message,
            action: action,
            affected_epic_ids: affected_epic_ids,
            skipped_epic_ids: skipped_epic_ids
          }.merge(extra)
        end

        def review_job_json(job)
          {
            id: job.id,
            title: job.issue_title.to_s,
            state: job.state,
            job_path: job_path(job),
            repository: {
              id: job.repository.id,
              slug: job.repository.slug
            },
            diff: job.initial_run&.agent_diff.to_s
          }
        end
      end
    end
  end
end
