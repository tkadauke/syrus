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
        PerformanceLogging.phase("dashboard_job.serialize", job_id: job.id, view: view) do
          dashboard_job_json(job)
        end
      end

      def dashboard_job_json(job)
        owner_user = PerformanceLogging.phase("dashboard_job.owner_user", job_id: job.id) { job_owner_user(job) }
        workflow_agent_provider = PerformanceLogging.phase("dashboard_job.workflow_agent_provider", job_id: job.id) { job.workflow_agent_provider }
        provider_availability = PerformanceLogging.phase("dashboard_job.provider_availability", job_id: job.id, provider: workflow_agent_provider) do
          provider_availability_for(workflow_agent_provider)
        end
        retry_state = PerformanceLogging.phase("dashboard_job.retry_state", job_id: job.id) { retry_state_for(job) }
        repository = PerformanceLogging.phase("dashboard_job.repository", job_id: job.id) { repository_json(job.repository) }
        source_chat = PerformanceLogging.phase("dashboard_job.source_chat", job_id: job.id) { App::JobSourceChat.for(job) }
        tags = PerformanceLogging.phase("dashboard_job.tags", job_id: job.id, tag_count: job.tags.size) { job.tags.map { |tag| tag_json(tag) } }

        payload = {
          type: "job",
          id: job.id,
          kind: job.kind,
          title: job.issue_title.presence || job.kind.humanize,
          title_pending: job.title_pending?,
          state: job.state,
          summary_state: summary_state(job),
          validity: job.validity,
          priority: job.priority,
          agent_provider: workflow_agent_provider,
          job_provider_setting: job.job_provider_setting,
          provider_availability: provider_availability,
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
          landing_queue_wait_reason: landing_queue_wait_reason_for(job),
          landing_queue_entry_key: landing_queue_entry_key_for(job),
          blocked_reason: blocked_reason_for(job),
          start_blocked_reason: job_start_blocked_reason(job),
          start_blocked_at: job_start_blocked_at(job),
          start_blocked_next_check_at: job_start_blocked_next_check_at(job),
          start_blocked_count: job_start_blocked_count(job),
          start_blocked_details: job_start_blocked_details(job),
          manual_paused: job.manual_paused?,
          manual_paused_at: job.manual_paused_at&.iso8601,
          manual_paused_by_user: owner_user_json(job.manual_paused_by_user),
          retry_state: retry_state,
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
          workflows_count: workflows_count_for(job),
          repository: repository,
          epic: job_epic_json(job.epic),
          owner_badge: owner_badge_for(owner_user),
          tags: tags,
          source_chat: source_chat,
          needs_attention: job.needs_attention?,
          needs_attention_reason: job.needs_attention_reason,
          paths: {
            job_path: job_path(job),
            source_path: source_job_path(job),
            app_pause_path: "/api/v1/app/jobs/#{job.id}/pause",
            app_unpause_path: "/api/v1/app/jobs/#{job.id}/unpause"
          }
        }

        if job.deployment_stage_statuses.any?
          stages = deployment_stages_for(job.repository)
          payload[:latest_deployment_stage] = App::DeploymentStageSummary.for(job, stages: stages) if stages.any?
        elsif job.landed_sha.present?
          payload[:latest_deployment_stage] = nil
        end

        payload
      end

      def workflows_count_for(job)
        return job.workflows.size unless defined?(@job_runtime_workflow_counts_by_job_id)

        @job_runtime_workflow_counts_by_job_id.fetch(job.id, 0)
      end

      def retry_state_for(job)
        return ::App::RetryState.for(job) unless defined?(@job_runtime_latest_runs_by_job_id)

        latest_run = @job_runtime_latest_runs_by_job_id[job.id]
        ::App::RetryState.for(
          job,
          latest_workflow: @job_runtime_latest_workflows_by_job_id[job.id],
          latest_run: latest_run,
          latest_run_diagnostic: latest_run && @job_runtime_run_diagnostics_by_run_id[latest_run.id],
          any_active_run: @job_runtime_active_job_ids.key?(job.id)
        )
      end

      def deployment_stages_configured?(repository)
        deployment_stages_for(repository).any?
      end

      def deployment_stages_for(repository)
        @deployment_stages_by_repository_id ||= {}
        @deployment_stages_by_repository_id.fetch(repository.id) do
          @deployment_stages_by_repository_id[repository.id] = PerformanceLogging.phase("dashboard_job.deployment_stages", repository_id: repository.id) do
            RepoDeploymentStagesReader.for_repository(repository).stages
          end
        end
      end

      def job_epic_json(epic)
        return nil unless epic

        {
          id: epic.id,
          number: epic.number,
          display_number: epic.slug,
          path: epic_path(epic),
          jobs_count: @epic_job_counts&.fetch(epic.id, 0) || 0,
          landed_jobs_count: @epic_landed_job_counts&.fetch(epic.id, 0) || 0
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
          simple_status: simple_epic_status(epic),
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

      def simple_epic_status(epic)
        epic.simple_status(jobs: epic.jobs.to_a)
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
        PerformanceLogging.phase("dashboard_workflow.serialize_one", workflow_id: workflow.id, trigger_kind: workflow.trigger_kind) do
          dashboard_workflow_json(workflow)
        end
      end

      def dashboard_workflow_json(workflow)
        job = workflow.job
        owner_user = PerformanceLogging.phase("dashboard_workflow.owner_user", workflow_id: workflow.id, job_id: job.id) { job_owner_user(job) }

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

      def job_start_blocked_next_check_at(job)
        start_blocked_data_by_job_id.dig(job.id, :next_check_at)
      end

      def job_start_blocked_count(job)
        start_blocked_data_by_job_id.dig(job.id, :count)
      end

      def job_start_blocked_details(job)
        start_blocked_data_by_job_id.dig(job.id, :details)
      end

      def start_blocked_data_by_job_id
        @start_blocked_data_by_job_id ||= begin
          active_scope = jobs_base_scope.where(state: %w[queued running landing]).select(:id)
          Workflow.where(job_id: active_scope, state: %w[queued running])
                  .where("artifacts LIKE ?", '%"start_blocked_reason"%')
                  .reorder(id: :desc)
                  .select(:job_id, :artifacts)
                  .each_with_object({}) do |wf, map|
            next if map.key?(wf.job_id)

            reason = wf.artifacts&.dig("start_blocked_reason")
            map[wf.job_id] = {
              reason: reason,
              at: wf.artifacts&.dig("start_blocked_at"),
              next_check_at: wf.artifacts&.dig("start_blocked_next_check_at"),
              count: wf.artifacts&.dig("start_blocked_count"),
              details: wf.artifacts&.dig("start_blocked_details")
            } if reason.present?
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
