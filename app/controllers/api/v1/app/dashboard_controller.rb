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
            message: "Dashboard preferences updated.",
            dashboard_preferences: Current.user.reload.dashboard_preferences
          }
        rescue ActionController::ParameterMissing, ArgumentError => e
          render_error("validation_failed", e.message, status: :unprocessable_content)
        end

        def landing_pause
          Current.user.update!(landing_paused: !Current.user.landing_paused?)
          LandingQueueProcessorJob.perform_later unless Current.user.landing_paused?

          render json: {
            message: Current.user.landing_paused? ? "Landing paused." : "Landing resumed.",
            landing_paused: Current.user.landing_paused?
          }
        end

        def bulk_jobs
          job_ids = Array(params[:job_ids]).filter_map { |id| Integer(id, exception: false) }.uniq
          if job_ids.empty?
            render_error("validation_failed", "Select at least one job.", status: :unprocessable_content)
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
          when "claim"
            bulk_claim_jobs(jobs)
          when "release_claim"
            bulk_release_claims(jobs)
          when "review_approve"
            bulk_review_approval(jobs)
          when "commit_review_approval"
            bulk_commit_review_approval(jobs)
          when "apply_tag"
            bulk_apply_tag(jobs)
          else
            render_error("validation_failed", "Choose a bulk action.", status: :unprocessable_content)
          end
        end

        def bulk_epics
          epic_ids = Array(params[:epic_ids]).filter_map { |id| Integer(id, exception: false) }.uniq
          if epic_ids.empty?
            render_error("validation_failed", "Select at least one Epic.", status: :unprocessable_content)
            return
          end

          epics = bulk_epic_scope(epic_ids)

          case params[:bulk_action].to_s
          when "start"
            bulk_start_epics(epics)
          else
            render_error("validation_failed", "Choose a bulk action.", status: :unprocessable_content)
          end
        end

        def epic_auto_approval
          epic = Current.user.epics.find(params[:id])
          epic.update!(params.expect(epic: [ :auto_approve_mode ]))

          render json: {
            message: "Epic auto-approval updated.",
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
          Current.user.jobs.joins(:repository)
                      .where(repositories: { archived_at: nil })
                      .where(id: job_ids)
                      .includes(:repository, :runs, :workflows)
        end

        def bulk_epic_scope(epic_ids)
          Current.user.epics.joins(:repository)
                      .where(repositories: { archived_at: nil })
                      .where(id: epic_ids)
                      .includes(:repository)
        end

        def bulk_retry_jobs(jobs, agent_provider: nil)
          if agent_provider.present? && !Current.user.agent_provider_configured?(agent_provider)
            render_error("validation_failed", "That agent is not available for retry.", status: :unprocessable_content)
            return
          end

          retried_ids = []
          circuit_errors = []
          jobs.find_each do |job|
            result = RetryWorkflowEnqueuer.call(job: job, agent_provider: agent_provider, automatic: true)
            retried_ids << job.id if result.success?
            circuit_errors << result.error if result.circuit&.open?
          end

          if retried_ids.empty?
            render_error("validation_failed", circuit_errors.first || "No selected jobs were eligible for retry.", status: :unprocessable_content)
          else
            agent_suffix = agent_provider.present? ? " with #{agent_provider.titleize}" : ""
            render_bulk_success(
              "Retry enqueued for #{helpers.pluralize(retried_ids.size, 'job')}#{agent_suffix}.",
              affected_job_ids: retried_ids,
              action: "retry"
            )
          end
        end

        def bulk_close_jobs(jobs)
          closed_ids = []
          jobs.find_each do |job|
            next if job.closed?

            job.cancel_active_runs_and_close!("cancelled")
            closed_ids << job.id
          end

          if closed_ids.empty?
            render_error("validation_failed", "No selected jobs were open.", status: :unprocessable_content)
          else
            render_bulk_success(
              "#{helpers.pluralize(closed_ids.size, 'job')} closed.",
              affected_job_ids: closed_ids,
              action: "close"
            )
          end
        end

        def bulk_approve_jobs(jobs)
          batch_id = SecureRandom.uuid
          approved_jobs = []
          skipped_auto_merge_disabled = []

          ActiveRecord::Base.transaction do
            jobs.each do |job|
              next unless job.may_approve?

              unless job.repository.auto_merge_enabled?
                skipped_auto_merge_disabled << job
                next
              end

              job.approve!(
                via: "bulk",
                by_user: Current.user,
                evidence: { "batch_id" => batch_id }
              )
              approved_jobs << job
            end
          end

          if approved_jobs.empty? && skipped_auto_merge_disabled.empty?
            render_error("validation_failed", "No selected jobs were awaiting approval.", status: :unprocessable_content)
          elsif approved_jobs.empty?
            render_error("validation_failed", bulk_auto_merge_disabled_message(skipped_auto_merge_disabled), status: :unprocessable_content)
          else
            github_note = bulk_github_approval_note(approved_jobs)
            skip_note = skipped_auto_merge_disabled.any? ? bulk_auto_merge_disabled_message(skipped_auto_merge_disabled) : nil
            render_bulk_success(
              [ "Approved #{helpers.pluralize(approved_jobs.size, 'job')} in batch #{batch_id}.", github_note, skip_note ].compact.join(" "),
              affected_job_ids: approved_jobs.map(&:id),
              skipped_job_ids: skipped_auto_merge_disabled.map(&:id),
              action: "approve",
              extra: { batch_id: batch_id }
            )
          end
        end

        def bulk_claim_jobs(jobs)
          claimed_ids = []
          jobs.find_each do |job|
            job.update!(claimed_by_user: Current.user, claimed_at: Time.current)
            claimed_ids << job.id
          end

          if claimed_ids.empty?
            render_error("validation_failed", "No selected jobs were available to claim.", status: :unprocessable_content)
          else
            render_bulk_success(
              "Claimed #{helpers.pluralize(claimed_ids.size, 'job')}.",
              affected_job_ids: claimed_ids,
              action: "claim"
            )
          end
        end

        def bulk_release_claims(jobs)
          released_ids = []
          jobs.where(claimed_by_user: Current.user).find_each do |job|
            job.update!(claimed_by_user: nil, claimed_at: nil)
            released_ids << job.id
          end

          if released_ids.empty?
            render_error("validation_failed", "No selected jobs are claimed by you.", status: :unprocessable_content)
          else
            render_bulk_success(
              "Released #{helpers.pluralize(released_ids.size, 'claim')}.",
              affected_job_ids: released_ids,
              action: "release_claim"
            )
          end
        end

        def bulk_review_approval(jobs)
          review_jobs = jobs.where(state: "implemented")
                            .includes(:repository, :runs)
                            .order(created_at: :desc)
                            .to_a
          if review_jobs.empty?
            render_error("validation_failed", "No selected jobs were awaiting approval.", status: :unprocessable_content)
            return
          end

          render json: {
            message: "Review selected jobs.",
            action: "review_approve",
            review_jobs: review_jobs.map { |job| review_job_json(job) }
          }
        end

        def bulk_commit_review_approval(jobs)
          choices_param = params[:approval_choices]
          choices = choices_param.respond_to?(:to_unsafe_h) ? choices_param.to_unsafe_h : {}
          ids_to_approve = choices.select { |_id, choice| choice == "approve" }.keys
          reviewed_jobs = jobs.where(id: ids_to_approve, state: "implemented")

          if reviewed_jobs.empty?
            render_error("validation_failed", "No reviewed jobs were approved.", status: :unprocessable_content)
            return
          end

          batch_id = SecureRandom.uuid
          approved_jobs = []
          ActiveRecord::Base.transaction do
            reviewed_jobs.each do |job|
              job.approve!(
                via: "bulk",
                by_user: Current.user,
                evidence: { "batch_id" => batch_id }
              )
              approved_jobs << job
            end
          end

          github_note = bulk_github_approval_note(approved_jobs)
          render_bulk_success(
            [ "Approved #{helpers.pluralize(approved_jobs.size, 'job')} in batch #{batch_id}.", github_note ].compact.join(" "),
            affected_job_ids: approved_jobs.map(&:id),
            action: "commit_review_approval",
            extra: { batch_id: batch_id }
          )
        end

        def bulk_apply_tag(jobs)
          tag = find_or_create_bulk_tag
          return unless tag

          applied_ids = []
          jobs.find_each do |job|
            job.job_tags.find_or_create_by!(tag: tag)
            applied_ids << job.id
          end

          render_bulk_success(
            "Applied #{tag.name} to #{helpers.pluralize(applied_ids.size, 'job')}.",
            affected_job_ids: applied_ids,
            action: "apply_tag",
            extra: { tag: { id: tag.id, name: tag.name, color: tag.color } }
          )
        end

        def find_or_create_bulk_tag
          if params[:tag_id].present?
            tag = Current.user.tags.find_by(id: params[:tag_id])
            unless tag
              render_error("not_found", "Tag not found.", status: :not_found)
              return nil
            end
            return tag
          end

          name = params[:tag_name].to_s.strip
          if name.blank?
            render_error("validation_failed", "Choose or enter a tag.", status: :unprocessable_content)
            return nil
          end

          Current.user.tags.find_or_create_by!(name: name) { |tag| tag.color = "gray" }
        end

        def bulk_start_epics(epics)
          if Current.user.product_owner?
            render_error("forbidden", "Product owners cannot advance Epics beyond backlog.", status: :forbidden)
            return
          end

          started_ids = []
          skipped_ids = []

          epics.find_each do |epic|
            if epic.ready? && epic.may_start?(actor: Current.user)
              epic.start!(actor: Current.user)
              started_ids << epic.id
            else
              skipped_ids << epic.id
            end
          end

          if started_ids.empty?
            render_error("validation_failed", "No selected Epics were ready to start.", status: :unprocessable_content)
          else
            render_epic_bulk_success(
              "#{helpers.pluralize(started_ids.size, 'Epic')} moved to In Progress.",
              affected_epic_ids: started_ids,
              skipped_epic_ids: skipped_ids,
              action: "start"
            )
          end
        end

        def bulk_auto_merge_disabled_message(skipped)
          repos = skipped.map { |job| job.repository.slug }.uniq.sort
          "Skipped #{helpers.pluralize(skipped.size, 'job')} whose repository has auto-merge disabled (#{repos.join(', ')}). Enable auto-merge in repository settings to approve."
        end

        def bulk_github_approval_note(jobs)
          results = jobs.map { |job| Job::ApprovalPropagator.approve(job, user: Current.user) }
          successes = results.count(&:success?)
          failures = results.select(&:failure?)
          notes = []
          notes << "GitHub reviews left for #{helpers.pluralize(successes, 'job')}." if successes.positive?
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
