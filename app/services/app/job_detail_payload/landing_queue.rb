module App
  class JobDetailPayload
    module LandingQueue
      extend ActiveSupport::Concern

      # Landing-queue payloads extracted from JobDetailPayload: this Job's entry in
      # the queue snapshot, the per-request snapshot memoization, and the waiting /
      # blocker job JSON. Mixed back in via ActiveSupport::Concern.

      def landing_queue_entry_json
        ensure_landing_queue_snapshot!
        return if @job.landing_queue_cached_at.blank?

        {
          position: @job.landing_queue_position,
          blocked_reason: @job.landing_queue_blocked_reason,
          waiting_for_jobs: landing_queue_waiting_jobs.map { |job| landing_queue_waiting_job_json(job) },
          blocker_jobs: landing_queue_blocker_jobs.map { |job| landing_queue_blocker_job_json(job, @job.landing_queue_entry_key) },
          dependency_edges: Array(@job.landing_queue_dependency_edges)
        }
      end

      def ensure_landing_queue_snapshot!
        return unless @job.approved? || @job.landing?
        return if @job.landing_queue_cached_at.present?

        LandingQueueProcessor.refresh_snapshot!(@user.jobs)
        @job.reload
      end

      def landing_queue_waiting_jobs
        ids = Array(@job.landing_queue_waiting_job_ids)
        return [] if ids.empty?

        Job.where(id: ids).index_by(&:id).values_at(*ids).compact
      end

      def landing_queue_blocker_jobs
        ids = Array(@job.landing_queue_blocker_job_ids)
        return [] if ids.empty?

        Job.where(id: ids).with_latest_workflow_snapshot.includes(:epic, :repository).index_by(&:id).values_at(*ids).compact
      end

      def landing_queue_waiting_job_json(job)
        {
          id: job.id,
          label: job.issue_number.present? ? "##{job.issue_number}" : job.slug,
          title: job.issue_title.presence || job.slug,
          job_path: "/jobs/#{job.id}"
        }
      end

      def landing_queue_blocker_job_json(job, entry_key)
        json = {
          id: job.id,
          title: job.issue_title.presence || job.slug,
          job_path: "/jobs/#{job.id}",
          state: job.state,
          pr_number: job.pr_number || job.external_pr_number,
          pr_path: App::Presentation.job_pr_url(job) || App::Presentation.external_pr_url(job),
          repository: { id: job.repository.id, slug: job.repository.slug, repository_path: repository_path(job.repository) },
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
