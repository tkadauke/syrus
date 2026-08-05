module App
  class DashboardPayload
    module LandingQueue
      extend ActiveSupport::Concern

      # Landing-queue payloads extracted from DashboardPayload: the queue chrome
      # and rows JSON, the per-request snapshot memoization, and the blocked-reason
      # / position / blocker-entry lookups. Mixed back in via ActiveSupport::Concern,
      # so it reads the same @user/@params and the *_json + scope helpers via ancestry.

      def landing_queue_json
        json = {
          visible: landing_queue_visible?,
          paused: user.landing_paused?,
          toggle_path: "/api/v1/app/dashboard/landing_pause"
        }
        json[:entries] = landing_queue_entries_json if landing_queue_visible?
        json
      end

      def landing_queue_chrome_json
        {
          visible: landing_queue_visible?,
          paused: user.landing_paused?,
          toggle_path: "/api/v1/app/dashboard/landing_pause"
        }
      end

      def landing_queue_visible?
        subject == "job" && active_smart_folder&.attention_preset == "landing_queue"
      end

      def blocked_folder_visible?
        subject == "job" && active_smart_folder&.attention_preset == "blocked"
      end

      def ensure_landing_queue_snapshot!
        return if @landing_queue_snapshot_checked

        @landing_queue_snapshot_checked = true
        candidates = jobs_base_scope.where(state: %w[ approved landing ])
        return unless candidates.where(landing_queue_cached_at: nil).exists?

        LandingQueueProcessor.refresh_snapshot!(jobs_base_scope)
      end

      def landing_queue_position_for(job)
        job.landing_queue_position if landing_queue_visible?
      end

      def landing_queue_blocked_reason_for(job)
        return unless landing_queue_visible?

        reason = job.landing_queue_blocked_reason.presence
        return nil if normal_landing_queue_wait_reason?(reason)

        reason || merge_train_start_blocked_reason_text_for(job) || landing_state_drift_reason_for(job)
      end

      def landing_queue_wait_reason_for(job)
        return unless landing_queue_visible?

        reason = job.landing_queue_blocked_reason.presence
        return reason if normal_landing_queue_wait_reason?(reason)
        return nil if merge_train_start_blocked_reason_for(job)

        merge_train_wait_reason_for(job)
      end

      def blocked_reason_for(job)
        return unless blocked_folder_visible?

        if job.landing_queue_blocked_reason.present? && !normal_landing_queue_wait_reason?(job.landing_queue_blocked_reason)
          return job.landing_queue_blocked_reason
        end
        return { key: "pr_not_mergeable" } if job.pr_mergeable == false

        dep = preloaded_blocked_deps_by_job_id[job.id]
        return unless dep

        if dep.depends_on_epic_id.present?
          { key: "waiting_epic_to_complete", params: { number: dep.depends_on_epic&.number } }
        elsif dep.depends_on_job_id.present?
          { key: "waiting_to_merge", params: { slug: dep.depends_on_job.slug } }
        else
          slug = dep.unresolved_slug
          { key: "waiting_to_merge", params: { slug: slug } } if slug.present?
        end
      end

      def preloaded_blocked_deps_by_job_id
        return {} unless blocked_folder_visible?

        @preloaded_blocked_deps_by_job_id ||= load_blocked_deps_by_job_id
      end

      def load_blocked_deps_by_job_id
        job_ids = (@current_jobs || []).map(&:id)
        return {} if job_ids.empty?

        JobDependency
          .where(job_id: job_ids)
          .includes(:depends_on_job, :depends_on_epic, :unresolved_chat_proposal)
          .order(:id)
          .reject { |dep| dep.depends_on_job&.dependency_succeeded? || dep.depends_on_epic&.done? }
          .each_with_object({}) { |dep, hash| hash[dep.job_id] ||= dep }
      end

      def landing_queue_entry_key_for(job)
        if landing_queue_visible?
          job.landing_queue_entry_key.presence || "job:#{job.id}"
        end
      end

      def normal_landing_queue_wait_reason?(reason)
        return false unless reason.respond_to?(:to_h)

        hash = reason.to_h
        (hash["key"] || hash[:key]).to_s == "waiting_epic_merge_train"
      end

      def merge_train_start_blocked_reason_text_for(job)
        reason = merge_train_start_blocked_reason_for(job)
        "Merge train queued: #{display_start_blocked_reason(reason)}" if reason
      end

      def merge_train_wait_reason_for(job)
        return unless AppSetting.merge_train_enabled?
        return unless job.epic_id.present?

        return "Merge train already active" if merge_train_active_for?(job)

        dispatcher_blocker = merge_train_dispatcher_blocker_for(job)
        "Merge train queued: #{dispatcher_blocker}" if dispatcher_blocker.present?
      end

      def landing_state_drift_reason_for(job)
        return unless job.landing?
        return if active_workflow_for_landing_queue_job?(job)

        "Landing state drift: no active workflow"
      end

      def merge_train_start_blocked_reason_for(job)
        merge_train_workflow_data_by_epic_id.dig(job.epic_id, :start_blocked_reason)
      end

      def merge_train_active_for?(job)
        merge_train_workflow_data_by_epic_id.dig(job.epic_id, :active) || active_merge_train_ids_by_epic_id.key?(job.epic_id)
      end

      def merge_train_dispatcher_blocker_for(job)
        merge_train_dispatcher_blockers_by_epic_id[job.epic_id]
      end

      def active_workflow_for_landing_queue_job?(job)
        active_workflow_job_ids.include?(job.id) || merge_train_active_for?(job)
      end

      def display_start_blocked_reason(reason)
        reason.to_s.tr("_", " ")
      end

      def merge_train_workflow_data_by_epic_id
        @merge_train_workflow_data_by_epic_id ||= begin
          epic_ids = landing_queue_epic_ids
          if epic_ids.empty?
            {}
          else
            workflows = Workflow
              .where(trigger_kind: "merge_train", state: %w[ queued running ], job_id: Job.where(epic_id: epic_ids).select(:id))
              .select(:job_id, :state, :artifacts, :created_at, :id)
              .order(created_at: :desc, id: :desc)
            epic_id_by_job_id = Job.where(epic_id: epic_ids).pluck(:id, :epic_id).to_h

            workflows.each_with_object({}) do |workflow, map|
              epic_id = epic_id_by_job_id[workflow.job_id]
              next unless epic_id

              data = (map[epic_id] ||= {})
              data[:active] = true
              data[:start_blocked_reason] ||= workflow.artifact("start_blocked_reason") if workflow.queued?
            end
          end
        end
      end

      def active_merge_train_ids_by_epic_id
        @active_merge_train_ids_by_epic_id ||= begin
          epic_ids = landing_queue_epic_ids
          epic_ids.empty? ? {} : MergeTrain.active.where(epic_id: epic_ids).pluck(:epic_id, :id).to_h
        end
      end

      def merge_train_dispatcher_blockers_by_epic_id
        @merge_train_dispatcher_blockers_by_epic_id ||= begin
          epic_ids = landing_queue_epic_ids
          epics = epic_ids.empty? ? [] : Epic.where(id: epic_ids).includes(:repository)
          epics.each_with_object({}) do |epic, map|
            reason = MergeTrainDispatcher.blocker_reason(epic)
            map[epic.id] = reason if reason.present?
          end
        end
      end

      def active_workflow_job_ids
        @active_workflow_job_ids ||= begin
          job_ids = current_landing_queue_jobs.map(&:id)
          job_ids.empty? ? Set.new : Workflow.active.where(job_id: job_ids).pluck(:job_id).to_set
        end
      end

      def landing_queue_epic_ids
        @landing_queue_epic_ids ||= current_landing_queue_jobs.filter_map(&:epic_id).uniq
      end

      def landing_queue_entries
        return [] unless landing_queue_visible?

        @landing_queue_entries ||= current_landing_queue_jobs.group_by { |job| job.landing_queue_entry_key.presence || "job:#{job.id}" }
      end

      def landing_queue_entries_json
        blocker_jobs_by_id = landing_queue_blocker_jobs_by_id

        landing_queue_entries.map do |key, jobs|
          blocker_ids = jobs.flat_map { |job| Array(job.landing_queue_blocker_job_ids) }.uniq
          {
            key: key,
            position: jobs.filter_map(&:landing_queue_entry_position).min,
            job_ids: jobs.map(&:id),
            blocker_jobs: blocker_ids.filter_map { |id| blocker_jobs_by_id[id] }.map { |job| landing_queue_blocker_job_json(job, key) },
            dependency_edges: jobs.flat_map { |job| Array(job.landing_queue_dependency_edges) }.uniq
          }
        end
      end

      def current_landing_queue_jobs
        current_result if @current_jobs.nil?
        @current_jobs || []
      end

      def landing_queue_blocker_jobs_by_id
        ids = current_landing_queue_jobs.flat_map { |job| Array(job.landing_queue_blocker_job_ids) }.uniq
        return {} if ids.empty?

        Job.where(id: ids).with_latest_workflow_snapshot.includes(:epic, :repository).index_by(&:id)
      end

      def landing_queue_blocker_job_json(job, entry_key)
        json = {
          id: job.id,
          title: job.issue_title.presence || job.slug,
          job_path: "/jobs/#{job.id}",
          state: job.state,
          pr_number: job.pr_number || job.external_pr_number,
          pr_path: App::Presentation.job_pr_url(job) || App::Presentation.external_pr_url(job),
          repository: repository_json(job.repository),
          latest_workflow_state: App::Presentation.workflow_dashboard_state(job.latest_workflow_state, job.latest_workflow_trigger_kind),
          latest_workflow_trigger_kind: job.latest_workflow_trigger_kind,
          latest_workflow_id: job.latest_workflow_id,
          started_at: job.started_at&.iso8601,
          created_at: job.created_at&.iso8601
        }
        if job.epic_id != landing_queue_entry_epic_id(entry_key)
          json[:epic_id] = job.epic_id
          json[:epic_title] = job.epic&.title
        end
        json
      end

      def landing_queue_entry_epic_id(entry_key)
        match = entry_key.to_s.match(/\Aepic:(\d+)\z/)
        match ? match[1].to_i : nil
      end
    end
  end
end
