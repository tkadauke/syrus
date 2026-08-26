module Steps
  # Single step of Workflows::UpstreamExport. Non-agentic. Opens or updates a
  # PR from the Job's own branch (already pushed by its own Initial/Retry
  # workflow's pr_open step) to the canonical repository
  # (`Repository#upstream_repository`)'s configured intake branch
  # (`DeliveryPolicy#upstream_export_target_branch`), reusing
  # PullRequestOpener's cross-repo `head_repository:` support the same way
  # ForkReviewApprover does.
  #
  # Idempotent: a JobPrLink (role: "upstream_export") already carrying a
  # pr_number means the PR was already opened — the same branch head keeps
  # the existing PR current without any further action needed here. Persists
  # `metadata: { "pr_state" => "open" }` either way, which is what
  # DeliveryStatus reads to surface :waiting_for_upstream_approval.
  class UpstreamExportPublish < Base
    def call
      canonical = repository.upstream_repository
      raise StepFailed, "upstream_export_publish: #{repository.slug} has no in-instance upstream_repository" unless canonical

      policy = DeliveryPolicy.for(repository: repository, job: job)
      target_branch = policy.upstream_export_target_branch(job)
      raise StepFailed, "upstream_export_publish: could not resolve an upstream_export target branch on #{canonical.slug}" if target_branch.blank?

      pr_number = open_or_update_pr!(canonical: canonical, target_branch: target_branch)
      record_upstream_export_link!(canonical: canonical, target_branch: target_branch, pr_number: pr_number)
      log("upstream_export_publish: #{repository.slug}:#{job.branch_name} -> #{canonical.slug}:#{target_branch} (PR ##{pr_number})")
    end

    private

    def open_or_update_pr!(canonical:, target_branch:)
      existing = existing_pr_number
      return existing if existing.present?

      client = GithubClient.for(repository: canonical, user: job.user)
      PullRequestOpener.new(
        canonical,
        client: client,
        head_repository: repository
      ).open(
        branch: job.branch_name,
        title: pr_title,
        body: pr_body,
        base: target_branch
      )
    end

    def existing_pr_number
      job.pr_links.find_by(role: JobPrLink::ROLE_UPSTREAM_EXPORT)&.pr_number
    end

    def record_upstream_export_link!(canonical:, target_branch:, pr_number:)
      JobPrLink.record!(
        job: job,
        role: JobPrLink::ROLE_UPSTREAM_EXPORT,
        source_repository_id: repository.id,
        source_ref: job.branch_name,
        target_repository_id: canonical.id,
        target_ref: target_branch,
        pr_number: pr_number,
        metadata: { "pr_state" => "open" }
      )
    end

    def pr_title
      upstream_source_workflow&.artifact("pr_title").presence || fallback_title
    end

    def pr_body
      base_body = upstream_source_workflow&.artifact("pr_body").presence || fallback_body
      "#{base_body}\n\n---\n_Exported from #{repository.slug}##{job.pr_number || job.issue_number} via Syrus upstream export. Review carefully — this PR was authored by an LLM._\n\n" \
        "#{PrProvenanceMarker.stamp(kind: 'syrus_job_export', job: job)}"
    end

    def upstream_source_workflow
      job.workflows.where(state: "succeeded").order(:created_at).last
    end

    def fallback_title
      "[syrus] #{repository.slug}##{job.issue_number || job.id}"
    end

    def fallback_body
      "Opened by Syrus following local approval in #{repository.slug}.\n\nReview the diff carefully — this PR was authored by an LLM."
    end
  end
end
