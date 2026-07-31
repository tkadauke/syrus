module App
  class DashboardPayload
    module RecordSerializers
      extend ActiveSupport::Concern

      # Per-record serialization extracted from DashboardPayload: turning a single
      # Job / Epic / Workflow / owner into its dashboard JSON, plus the owner-badge
      # and epic job-count helpers. Mixed back in via ActiveSupport::Concern, so it
      # reads the same @user/@params and the tag_json/repository_json/summary_state/
      # owner_user_json helpers through the include ancestry.

      def job_json(job)
        owner_user = job_owner_user(job)

        {
          type: "job",
          id: job.id,
          kind: job.kind,
          title: job.issue_title.presence || job.kind.humanize,
          title_pending: job.title_pending?,
          state: job.state,
          summary_state: summary_state(job),
          validity: job.validity,
          priority: job.priority,
          agent_provider: job.agent_provider,
          provider_availability: ::App::ProviderAvailability.for_user(user, job.agent_provider),
          total_cost_usd: job.display_total_cost_usd&.to_f,
          issue_number: job.issue_number,
          issue_url: App::Presentation.job_issue_url(job),
          branch_name: job.branch_name,
          pr_number: job.pr_number || job.external_pr_number,
          active_workflow_trigger_kind: active_workflow_trigger_kind(job),
          latest_workflow_id: job.latest_workflow_id,
          latest_workflow_trigger_kind: job.latest_workflow_trigger_kind,
          pr_url: job.pr_number.present? ? App::Presentation.job_pr_url(job) : App::Presentation.external_pr_url(job),
          latest_workflow_state: App::Presentation.workflow_dashboard_state(job.latest_workflow_state, job.latest_workflow_trigger_kind),
          landing_queue_position: landing_queue_position_for(job),
          landing_queue_blocked_reason: landing_queue_blocked_reason_for(job),
          landing_queue_entry_key: landing_queue_entry_key_for(job),
          blocked_reason: blocked_reason_for(job),
          start_blocked_reason: job_start_blocked_reason(job),
          start_blocked_at: job_start_blocked_at(job),
          retry_state: ::App::RetryState.for(job),
          created_at: job.created_at&.iso8601,
          updated_at: job.updated_at&.iso8601,
          started_at: job.started_at&.iso8601,
          finished_at: job.finished_at&.iso8601,
          approved_at: job.approved_at&.iso8601,
          owner_user_id: job.owner_user_id,
          owner_user: owner_user_json(owner_user),
          claimed_at: job.claimed_at&.iso8601,
          claimed_by_user: claim_owner_json(job.claimed_by_user),
          claimed_by_current_user: job.claimed_by_user_id == user.id,
          dependencies_overridden_at: job.dependencies_overridden_at&.iso8601,
          last_feedback_addressed_at: job.last_feedback_addressed_at&.iso8601,
          last_seen_comment_at: job.last_seen_comment_at&.iso8601,
          pr_mergeable_checked_at: job.pr_mergeable_checked_at&.iso8601,
          commits_behind_base: job.commits_behind_base,
          workflows_count: job.workflows.size,
          repository: repository_json(job.repository),
          epic: job_epic_json(job.epic),
          owner_badge: owner_badge_for(owner_user),
          tags: job.tags.map { |tag| tag_json(tag) },
          source_chat: App::JobSourceChat.for(job),
          needs_attention: job.needs_attention?,
          needs_attention_reason: job.needs_attention_reason,
          paths: {
            job_path: job_path(job),
            source_path: source_job_path(job)
          }
        }
      end

      def job_epic_json(epic)
        return nil unless epic

        {
          id: epic.id,
          number: epic.number,
          display_number: epic.slug,
          path: epic_path(epic)
        }
      end

      def claim_owner_json(owner)
        return unless owner

        {
          id: owner.id,
          display_name: owner.display_name,
          profile_path: profile_path(owner)
        }
      end

      def epic_json(epic)
        owner_user = epic_owner_user(epic)

        {
          type: "epic",
          id: epic.id,
          number: epic.number,
          display_number: epic.slug,
          title: epic.title,
          description: epic.description.to_s,
          state: epic.state,
          stuck: epic.stuck?,
          all_jobs_closed: epic.all_jobs_closed?,
          owner: owner_json(epic.owner),
          owned_by_current_user: epic.owner_user_id == user.id || epic.claimed_by?(user),
          claimable: epic.claimable?,
          owner_badge: owner_badge_for(owner_user, claimable: epic.claimable?),
          claimed_at: epic.claimed_at&.iso8601,
          auto_approve_mode: epic.auto_approve_mode,
          owner_user_id: owner_user&.id,
          owner_status: epic_owner_status(epic),
          owner_user: owner_user_json(owner_user),
          jobs_count: epic.jobs.size,
          landed_jobs_count: epic_landed_jobs_count(epic),
          job_state_counts: epic_job_state_counts(epic),
          max_commits_behind_base: epic.jobs.select { |j| j.parent_job_id.nil? }.filter_map(&:commits_behind_base).max,
          created_at: epic.created_at&.iso8601,
          updated_at: epic.updated_at&.iso8601,
          done_at: epic.done_at&.iso8601,
          archived_at: epic.archived_at&.iso8601,
          repository: repository_json(epic.repository),
          paths: {
            epic_path: epic_path(epic),
            edit_epic_path: edit_epic_path(epic),
            app_state_path: "/api/v1/app/epics/#{epic.id}/state",
            app_claim_path: "/api/v1/app/epics/#{epic.id}/claim",
            app_unclaim_path: "/api/v1/app/epics/#{epic.id}/unclaim"
          }
        }
      end

      def epic_landed_jobs_count(epic)
        epic.jobs.count { |job| job.closed? && Epic::MERGED_JOB_CLOSURE_REASONS.include?(job.closure_reason) }
      end

      def epic_job_state_counts(epic)
        epic.jobs.each_with_object(Hash.new(0)) do |job, counts|
          state = if job.closure_reason == "preempted" || job.closure_reason&.start_with?("external_pr_")
                    "preempted"
                  else
                    job.state
                  end
          counts[state] += 1
        end.to_h
      end

      def owner_json(owner)
        return nil unless owner

        {
          id: owner.id,
          email_address: owner.email_address,
          display_name: owner.team_display_name,
          profile_path: profile_path(owner)
        }
      end

      def workflow_json(workflow)
        job = workflow.job
        owner_user = job_owner_user(job)

        {
          type: "workflow",
          id: workflow.id,
          slug: workflow.slug,
          path: App::WorkflowNavigation.path(workflow),
          state: App::Presentation.workflow_dashboard_state(workflow.state, workflow.trigger_kind),
          trigger_kind: workflow.trigger_kind,
          agent_provider: workflow.agent_provider,
          created_at: workflow.created_at&.iso8601,
          updated_at: workflow.updated_at&.iso8601,
          started_at: workflow.started_at&.iso8601,
          finished_at: workflow.finished_at&.iso8601,
          cleaned_up_at: workflow.cleaned_up_at&.iso8601,
          steps_count: workflow.steps.size,
          job: {
            id: job.id,
            title: job.issue_title.presence || job.kind.humanize,
            title_pending: job.title_pending?,
            state: job.state,
            repository: repository_json(job.repository),
            owner_user: owner_user_json(owner_user),
            owner_badge: owner_badge_for(owner_user),
            path: job_path(job)
          }
        }
      end

      def epic_owner_status(epic)
        owner_user = epic_owner_user(epic)
        return "unclaimed" if owner_user.nil?
        return "mine" if owner_user.id == user.id

        "other_owned"
      end

      def job_start_blocked_reason(job)
        start_blocked_data_by_job_id.dig(job.id, :reason)
      end

      def job_start_blocked_at(job)
        start_blocked_data_by_job_id.dig(job.id, :at)
      end

      def start_blocked_data_by_job_id
        @start_blocked_data_by_job_id ||= begin
          queued_scope = jobs_base_scope.where(state: "queued").select(:id)
          Workflow.where(job_id: queued_scope, state: "queued")
                  .where("artifacts LIKE ?", '%"start_blocked_reason"%')
                  .select(:job_id, :artifacts)
                  .each_with_object({}) do |wf, map|
            reason = wf.artifacts&.dig("start_blocked_reason")
            map[wf.job_id] = { reason: reason, at: wf.artifacts&.dig("start_blocked_at") } if reason.present?
          end
        end
      end

      def job_owner_user(job)
        job.owner_user || job.user
      end

      def epic_owner_user(epic)
        epic.owner_user || epic.owner
      end

      def owner_badge_for(owner_user, claimable: false)
        return nil if team_user_count <= 1
        return { label: "Claimable", kind: "claimable" } if claimable && owner_user.nil?
        return nil if owner_user.nil? || owner_user.id == user.id

        {
          label: owner_user.team_display_name,
          kind: "other_user"
        }
      end
    end
  end
end
