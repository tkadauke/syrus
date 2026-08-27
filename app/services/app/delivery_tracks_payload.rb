# Repository detail page "Delivery" section — tracks table, ref-movement
# action availability, recent ref-movement workflows, and recent PR
# ingestion classifications. UI-only glue over facts already recorded by
# earlier Jobs of EPIC-268 (DeliveryPolicy, JobPrLink, RefMovementAction,
# PrProvenanceClassifier) — no new state is derived or persisted here.
module App
  class DeliveryTracksPayload
    include Rails.application.routes.url_helpers

    RECENT_LIMIT = 10
    REF_MOVEMENT_TRIGGER_KINDS = %w[promotion hotfix_sync upstream_export].freeze

    def self.for(repository:)
      new(repository: repository).payload
    end

    def initialize(repository:)
      @repository = repository
      @policy = DeliveryPolicy.for(repository: repository)
    end

    def payload
      return nil unless configured?

      {
        tracks: tracks_json,
        ref_movement_actions: RefMovementActionsSummary.for(repository: repository),
        recent_ref_movement_workflows: recent_ref_movement_workflows_json,
        recent_pr_ingestions: recent_pr_ingestions_json
      }
    end

    private

    attr_reader :repository, :policy

    # Every repository resolves an implicit single "default" track even
    # without a `delivery:` block — only render the section once there is
    # something beyond that to show.
    def configured?
      policy.tracks.size > 1 ||
        policy.promotion_enabled? ||
        policy.hotfix_sync_enabled? ||
        policy.upstream_export_enabled? ||
        policy.ref_movement_actions.any?
    end

    def tracks_json
      policy.tracks.map do |name, track|
        {
          name: name,
          branch: track.branch,
          is_default: name == SyrusYml::DEFAULT_DELIVERY_TRACK_NAME,
          review_grade_phase: track.review_grade_phase,
          landing_grade_phase: track.landing_grade_phase,
          branch_health_grade_phase: track.branch_health_grade_phase,
          health: track.branch == repository.default_branch ? repository.main_health : nil,
          queue_length: queue_length_for(track),
          last_promotion: track.branch == promotion_source_branch ? last_promotion : nil,
          last_hotfix_sync: track.branch == hotfix_sync_target_branch ? last_hotfix_sync : nil
        }
      end
    end

    def queue_length_for(track)
      landing_queue_jobs.count { |job| policy.job_landing_branch(job) == track.branch }
    end

    def landing_queue_jobs
      @landing_queue_jobs ||= repository.jobs.landing_queue.to_a
    end

    def promotion_source_branch
      @promotion_source_branch ||= policy.promotion_enabled? ? policy.promotion_source_branch : nil
    end

    def hotfix_sync_target_branch
      @hotfix_sync_target_branch ||= policy.hotfix_sync_enabled? ? policy.hotfix_sync_target_branch : nil
    end

    def last_promotion
      return nil unless policy.promotion_enabled?

      @last_promotion ||= last_ref_movement_json(trigger_kind: "promotion")
    end

    def last_hotfix_sync
      return nil unless policy.hotfix_sync_enabled?

      @last_hotfix_sync ||= last_ref_movement_json(trigger_kind: "hotfix_sync")
    end

    def last_ref_movement_json(trigger_kind:)
      workflow = Workflow.joins(:job)
        .where(trigger_kind: trigger_kind, state: "succeeded", jobs: { repository_id: repository.id })
        .reorder(created_at: :desc, id: :desc)
        .first
      return nil unless workflow

      {
        workflow_id: workflow.id,
        finished_at: workflow.finished_at&.iso8601,
        source_ref: workflow.artifact("#{trigger_kind}_source_branch"),
        target_ref: workflow.artifact("#{trigger_kind}_target_branch")
      }
    end

    def recent_ref_movement_workflows_json
      Workflow.joins(:job)
        .where(trigger_kind: REF_MOVEMENT_TRIGGER_KINDS, jobs: { repository_id: repository.id })
        .includes(:job)
        .reorder(created_at: :desc, id: :desc)
        .limit(RECENT_LIMIT)
        .map { |workflow| ref_movement_workflow_json(workflow) }
    end

    def ref_movement_workflow_json(workflow)
      job = workflow.job
      link = job.pr_links.find { |pr_link| pr_link.role == workflow.trigger_kind }

      {
        id: workflow.id,
        trigger_kind: workflow.trigger_kind,
        state: workflow.state,
        job_id: job.id,
        job_slug: job.slug,
        source_ref: link&.source_ref || workflow.artifact("#{workflow.trigger_kind}_source_branch"),
        target_ref: link&.target_ref || workflow.artifact("#{workflow.trigger_kind}_target_branch"),
        target_repository_slug: link&.target_repository_id ? Repository.find_by(id: link.target_repository_id)&.slug : nil,
        pr_number: link&.pr_number,
        pr_state: link&.metadata.to_h["pr_state"],
        created_at: workflow.created_at&.iso8601,
        finished_at: workflow.finished_at&.iso8601,
        job_path: job_path(job),
        workflow_path: "#{job_path(job)}?tab=workflows#workflow-#{workflow.id}"
      }
    end

    def recent_pr_ingestions_json
      imported_jobs = repository.jobs.where(kind: "external_pr")
        .includes(:pr_links)
        .reorder(created_at: :desc, id: :desc)
        .limit(RECENT_LIMIT)
        .to_a

      attached_links = JobPrLink.where(role: JobPrLink::ROLE_EXTERNAL_INGEST, target_repository_id: repository.id)
        .where.not(job_id: imported_jobs.map(&:id))
        .includes(:job)
        .reorder(created_at: :desc, id: :desc)
        .limit(RECENT_LIMIT)

      entries = imported_jobs.map { |job| pr_ingestion_json(job: job, link: job.pr_links.find { |pr_link| pr_link.role == JobPrLink::ROLE_EXTERNAL_INGEST }) }
      entries += attached_links.filter_map { |link| link.job && pr_ingestion_json(job: link.job, link: link) }

      entries.sort_by { |entry| entry[:created_at].to_s }.reverse.first(RECENT_LIMIT)
    end

    def pr_ingestion_json(job:, link:)
      metadata = link&.metadata.to_h
      {
        job_id: job.id,
        job_slug: job.slug,
        job_path: job_path(job),
        pr_number: link&.pr_number || job.external_pr_number,
        classification: metadata["provenance"].presence || "external_unknown",
        ingest_mode: metadata["ingest_mode"],
        source_repo_slug: metadata["source_repo_slug"],
        created_at: job.created_at&.iso8601
      }
    end
  end
end
