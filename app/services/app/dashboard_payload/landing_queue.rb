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
        job.landing_queue_blocked_reason if landing_queue_visible?
      end

      def blocked_reason_for(job)
        return unless blocked_folder_visible?

        return job.landing_queue_blocked_reason if job.landing_queue_blocked_reason.present?
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
