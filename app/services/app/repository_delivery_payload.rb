# Read-only serializer for the repository/dashboard delivery UI (EPIC-268's
# final "UI" Job). Exposes what earlier Jobs in the Epic already computed —
# `DeliveryPolicy`, `RefMovementAction`, `JobPrLink`, and the promotion/
# hotfix_sync/upstream_export `Workflow`s — as one JSON section; it adds no
# new delivery business logic of its own.
module App
  class RepositoryDeliveryPayload
    include Rails.application.routes.url_helpers

    RECENT_LIMIT = 10
    REF_MOVEMENT_WORKFLOW_KINDS = %w[ promotion hotfix_sync upstream_export ].freeze

    def self.call(repository:)
      new(repository: repository).call
    end

    def initialize(repository:)
      @repository = repository
      @policy = DeliveryPolicy.for(repository: repository)
    end

    def call
      {
        tracks: tracks_json,
        promotion: {
          enabled: policy.promotion_enabled?,
          mode: policy.promotion_mode,
          source_branch: policy.promotion_source_branch,
          target_branch: policy.promotion_target_branch,
          requires_operator_approval: policy.requires_operator_approval_for_promotion?
        },
        hotfix_sync: {
          enabled: policy.hotfix_sync_enabled?,
          mode: policy.hotfix_sync_mode,
          source_branch: policy.hotfix_sync_source_branch,
          target_branch: policy.hotfix_sync_target_branch
        },
        upstream_export: {
          enabled: policy.upstream_export_enabled?,
          mode: policy.upstream_export_mode,
          after_local_approval: policy.export_upstream_after_local_approval?,
          target_branch: policy.upstream_export_target_branch
        },
        ref_movement_actions: ref_movement_actions_json,
        recent_ref_movement_actions: recent_ref_movement_actions_json,
        recent_workflows: recent_workflows_json,
        recent_pr_ingestions: recent_pr_ingestions_json,
        paths: {
          app_dispatch_ref_movement_action_repository_path: "/api/v1/app/repositories/#{repository.id}/dispatch_ref_movement_action"
        }
      }
    end

    private

    attr_reader :repository, :policy

    def tracks_json
      policy.tracks.map do |name, track|
        {
          name: name,
          default: name == SyrusYml::DEFAULT_DELIVERY_TRACK_NAME,
          branch: track.branch,
          review_grade_phase: track.review_grade_phase,
          landing_grade_phase: track.landing_grade_phase,
          branch_health_grade_phase: track.branch_health_grade_phase,
          health: track_health(track),
          landing_queue_count: landing_queue_count(name),
          queue_path: track_queue_path(name),
          last_promotion_or_sync_at: name == SyrusYml::DEFAULT_DELIVERY_TRACK_NAME ? last_promotion_or_sync_at&.iso8601 : nil
        }
      end
    end

    # Promotion/hotfix-sync ref movement is repository-wide today, not
    # per-track (both always resolve to the "default" track's branch — see
    # DeliveryPolicy#promotion_source_branch/#hotfix_sync_target_branch), so
    # this is only ever attached to the "default" track row above.
    def last_promotion_or_sync_at
      return @last_promotion_or_sync_at if defined?(@last_promotion_or_sync_at)

      @last_promotion_or_sync_at = Workflow.where(job: repository.jobs, trigger_kind: %w[ promotion hotfix_sync ])
        .where.not(finished_at: nil)
        .order(finished_at: :desc)
        .limit(1)
        .pick(:finished_at)
    end

    def track_health(track)
      return repository.main_health if track.branch == repository.default_branch

      "not_monitored"
    end

    def landing_queue_count(track_name)
      scope = Job.landing_queue.where(repository_id: repository.id)
      if track_name == SyrusYml::DEFAULT_DELIVERY_TRACK_NAME
        scope.where(delivery_track: [ nil, track_name ]).count
      else
        scope.where(delivery_track: track_name).count
      end
    end

    # Only worth a direct link once a repository actually has more than one
    # landing target — a single-track repository's landing queue is already
    # the plain "Landing queue" dashboard smart folder.
    def track_queue_path(track_name)
      return nil unless policy.tracks.size > 1

      tree = {
        "and" => [
          { "field" => "repository_id", "op" => "is", "value" => repository.id },
          { "field" => "delivery_track", "op" => "is", "value" => track_name },
          { "field" => "attention", "op" => "is", "value" => "landing_queue" }
        ]
      }
      "/dashboard/jobs?#{Filters::QueryParam::PARAM_NAME}=#{Filters::QueryParam.encode(tree)}"
    end

    def ref_movement_actions_json
      policy.ref_movement_actions.map do |name, config|
        available, reason = RefMovementActions::Base.for(name).available?(repository: repository)
        {
          name: name,
          enabled: config.enabled,
          mode: config.mode,
          grade_phases: config.grade_phases,
          available: config.enabled && available,
          blocked_reason: config.enabled ? (available ? nil : reason) : "not enabled in delivery.ref_movement_actions"
        }
      end
    end

    def recent_ref_movement_actions_json
      RefMovementAction.where(repository: repository)
        .order(created_at: :desc)
        .limit(RECENT_LIMIT)
        .map { |record| ref_movement_action_json(record) }
    end

    def ref_movement_action_json(record)
      job = record.job
      workflow = record.workflow
      {
        id: record.id,
        action_name: record.action_name,
        state: record.state,
        blocked_reason: record.blocked_reason,
        requested_by: record.requested_by_user.email_address,
        source_kind: record.source_kind,
        source_ref: record.source_ref,
        target_kind: record.target_kind,
        target_ref: record.target_ref,
        target_repository_slug: record.target_repository&.slug,
        target_inferred: record.target_inferred,
        job: job && { id: job.id, slug: job.slug, job_path: job_path(job) },
        workflow_path: job && workflow ? "#{job_path(job)}?tab=workflows#workflow-#{workflow.id}" : nil,
        created_at: record.created_at.iso8601
      }
    end

    def recent_workflows_json
      Workflow.where(job: repository.jobs, trigger_kind: REF_MOVEMENT_WORKFLOW_KINDS)
        .order(created_at: :desc)
        .limit(RECENT_LIMIT)
        .includes(job: :pr_links)
        .map { |workflow| recent_workflow_json(workflow) }
    end

    def recent_workflow_json(workflow)
      job = workflow.job
      link = job.pr_links.find { |candidate| candidate.role == workflow.trigger_kind }
      {
        id: workflow.id,
        trigger_kind: workflow.trigger_kind,
        trigger_kind_label: Workflow::TriggerKind.label_for(workflow.trigger_kind),
        state: workflow.state,
        job: { id: job.id, slug: job.slug, job_path: job_path(job) },
        source_ref: link&.source_ref,
        target_ref: link&.target_ref,
        target_repository_slug: link&.target_repository_id ? Repository.find_by(id: link.target_repository_id)&.slug : nil,
        created_at: workflow.created_at.iso8601,
        finished_at: workflow.finished_at&.iso8601
      }
    end

    def recent_pr_ingestions_json
      repository.jobs.where(kind: "external_pr")
        .order(created_at: :desc)
        .limit(RECENT_LIMIT)
        .includes(:pr_links)
        .map { |job| pr_ingestion_json(job) }
    end

    def pr_ingestion_json(job)
      link = job.pr_links.find { |candidate| candidate.role == JobPrLink::ROLE_EXTERNAL_INGEST }
      metadata = link&.metadata.to_h
      {
        job: { id: job.id, slug: job.slug, job_path: job_path(job) },
        pr_number: job.external_pr_number,
        external_pr_url: ::App::Presentation.external_pr_url(job),
        external_pr_author: job.external_pr_author,
        provenance: metadata["provenance"] || PrProvenanceClassifier::EXTERNAL_UNKNOWN,
        ingest_mode: metadata["ingest_mode"],
        source_repo_slug: metadata["source_repo_slug"],
        created_at: job.created_at.iso8601
      }
    end
  end
end
