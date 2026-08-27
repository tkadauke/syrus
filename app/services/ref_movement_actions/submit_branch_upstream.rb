module RefMovementActions
  # `submit_branch_upstream`: export a whole development-track branch (not
  # one Job's per-job branch) to the canonical repository's intake branch —
  # Story 11's "Bob's PR" shape `PrProvenanceClassifier` already classifies
  # as `syrus_branch_export` on the receiving end. Reuses
  # `Workflows::UpstreamExport`/`Steps::UpstreamExportPublish` exactly as-is:
  # that step only ever opens/updates a PR from `job.branch_name` (already
  # pushed) to the resolved target branch, so a synthetic anchor Job whose
  # `branch_name` is the already-existing source branch is enough — the same
  # synthetic-anchor-Job pattern `PromotionDispatcher`/`HotfixSyncDispatcher`
  # use for repository-wide ref movement that isn't about any single dev
  # Job's own PR.
  class SubmitBranchUpstream < Base
    def available?(repository:, job: nil, source_branch: nil)
      canonical = repository.upstream_repository
      return [ false, "repository has no in-instance upstream_repository" ] unless canonical

      policy = DeliveryPolicy.for(repository: repository)
      return [ false, "upstream_export is not enabled" ] unless policy.upstream_export_enabled?

      branch = source_branch.presence || policy.job_landing_branch
      return [ false, "a submit_branch_upstream export for #{branch} is already in flight" ] if pending_for?(repository, branch)

      [ true, nil ]
    end

    def self.pending_for?(repository, branch)
      repository.jobs.open_threads.where(issue_number: nil, branch_name: branch)
        .joins(:workflows).where(workflows: { trigger_kind: "upstream_export", state: %w[queued running] })
        .exists?
    end

    def pending_for?(repository, branch)
      self.class.pending_for?(repository, branch)
    end

    private

    def call(repository:, actor:, config:, source:, target:)
      policy = DeliveryPolicy.for(repository: repository)
      source_branch = source.presence || policy.job_landing_branch

      ok, reason = available?(repository: repository, source_branch: source_branch)
      return { state: "blocked", blocked_reason: reason, source_ref: source_branch } unless ok

      canonical = repository.upstream_repository
      target_inferred = target.blank?
      target_branch = target.presence || policy.upstream_export_target_branch
      return { state: "blocked", blocked_reason: "could not resolve an upstream_export target branch on #{canonical.slug}", source_ref: source_branch } if target_branch.blank?

      job = Job.create!(
        user: actor,
        repository: repository,
        kind: "direct",
        issue_number: nil,
        branch_name: source_branch,
        issue_title: "Submit #{source_branch} to #{canonical.slug}:#{target_branch}",
        issue_body: "Automated ref-movement branch export of `#{source_branch}` to `#{canonical.slug}:#{target_branch}`.",
        agent_provider: repository.effective_agent_provider,
        priority: "high"
      )

      workflow = WorkUnits::Launcher.instantiate(
        kind: "upstream_export",
        job: job,
        source_type: "ref_movement_action"
      )
      WorkUnits::Launcher.start!(workflow)

      {
        state: "dispatched",
        job: job,
        source_kind: "branch",
        source_ref: source_branch,
        target_kind: "upstream_intake",
        target_ref: target_branch,
        target_repository: canonical,
        target_inferred: target_inferred,
        workflow: workflow
      }
    end
  end
end
