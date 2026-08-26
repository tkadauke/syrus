module RefMovementActions
  # `send_job_upstream`: export one already-approved dev Job's own branch to
  # the canonical (`Repository#upstream_repository`) repository's intake
  # branch, on demand rather than waiting for the automatic
  # post-local-approval trigger. Reuses `UpstreamExportDispatcher` (with
  # `explicit: true`, so it doesn't gate on
  # `DeliveryPolicy#export_upstream_after_local_approval?` — that flag only
  # controls the *automatic* trigger) — no bespoke export logic here.
  class SendJobUpstream < Base
    def available?(repository:, job: nil, source_branch: nil)
      return [ false, "job is required for send_job_upstream" ] unless job
      return [ false, "job belongs to a different repository" ] unless job.repository_id == repository.id
      return [ false, "job is not open" ] unless job.open?
      return [ false, "job has no branch yet" ] if job.branch_name.blank?

      canonical = repository.upstream_repository
      return [ false, "repository has no in-instance upstream_repository" ] unless canonical

      policy = DeliveryPolicy.for(repository: repository, job: job)
      return [ false, "upstream_export is not enabled" ] unless policy.upstream_export_enabled?
      return [ false, "already exported" ] if already_exported?(job)
      return [ false, "an upstream_export workflow is already in flight" ] if active_export_workflow?(job)

      [ true, nil ]
    end

    private

    def call(repository:, actor:, config:, source:, target:)
      job = source
      raise ArgumentError, "send_job_upstream requires a Job as source" unless job.is_a?(Job)

      ok, reason = available?(repository: repository, job: job)
      return { state: "blocked", blocked_reason: reason, job: job } unless ok

      canonical = repository.upstream_repository
      target_branch = DeliveryPolicy.for(repository: repository, job: job).upstream_export_target_branch(job)

      UpstreamExportDispatcher.call!(job, explicit: true)

      {
        state: "dispatched",
        job: job,
        source_kind: "job_branch",
        source_ref: job.branch_name,
        target_kind: "upstream_intake",
        target_ref: target_branch,
        target_repository: canonical,
        target_inferred: true,
        workflow: job.workflows.where(trigger_kind: "upstream_export").order(:created_at, :id).last
      }
    end

    def already_exported?(job)
      job.pr_links.find_by(role: JobPrLink::ROLE_UPSTREAM_EXPORT)&.pr_number.present?
    end

    def active_export_workflow?(job)
      job.workflows.where(trigger_kind: "upstream_export", state: %w[queued running]).exists?
    end
  end
end
