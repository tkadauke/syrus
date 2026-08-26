module ExternalPrIngestions
  # Story 8/9/10: one Syrus Job exported as an upstream PR (Casey's PR). If
  # the exporting Job is visible on this same instance — its head
  # repository is itself a registered `Repository` and the branch's
  # trailing job id resolves to a real row on it — attach this PR to that
  # Job instead of creating a redundant review Job: the Job's branch already
  # passed its own grade loop via the `initial`/`retry` workflow that got it
  # approved, the same reasoning `Workflows::UpstreamExport` itself uses to
  # skip regrading. Otherwise (a different, unlinked Syrus instance) create
  # an imported Job with provenance recorded, and grade it defensively like
  # any other unverified external contribution.
  class SyrusJobExport < Base
    def ingest!(repository:, pr:, fork_pr:)
      source = source_job(pr)
      return attach!(source_job: source, repository: repository, pr: pr) if source

      create_imported_job!(repository: repository, pr: pr, fork_pr: fork_pr)
    end

    private

    def source_job(pr)
      job_id = PrProvenanceClassifier.job_id_from_branch(pr.head&.ref)
      head_repo = head_repository(pr)
      return nil unless job_id && head_repo

      Job.find_by(id: job_id, repository: head_repo)
    end

    def head_repository(pr)
      owner, name = pr.head&.repo&.full_name.to_s.split("/", 2)
      return nil if owner.blank? || name.blank?

      Repository.find_by(owner: owner, name: name)
    end

    def attach!(source_job:, repository:, pr:)
      # `PollAllExternalOpenPrsJob` re-polls every 5 minutes and the exported
      # PR stays open (and un-numbered on `repository`'s own Job table)
      # indefinitely — without this guard every tick would re-attach and
      # re-log the same link.
      already_attached = source_job.pr_links.exists?(role: JobPrLink::ROLE_EXTERNAL_INGEST, pr_number: pr.number)
      return source_job if already_attached

      JobPrLink.record!(
        job: source_job,
        role: JobPrLink::ROLE_EXTERNAL_INGEST,
        source_repository_id: source_job.repository_id,
        source_ref: pr.head&.ref,
        target_repository_id: repository.id,
        target_ref: pr.base&.ref,
        pr_number: pr.number,
        metadata: { "provenance" => "syrus_job_export", "ingest_mode" => "attached" }
      )
      Rails.logger.info("[ExternalPrIngestions::SyrusJobExport] attached #{repository.slug}##{pr.number} to existing #{source_job.slug}")
      source_job
    end

    def create_imported_job!(repository:, pr:, fork_pr:)
      job = JobFactory.create!(repository: repository, pr: pr, fork_pr: fork_pr)
      JobPrLink.record!(
        job: job,
        role: JobPrLink::ROLE_EXTERNAL_INGEST,
        source_repository_id: nil,
        source_ref: pr.head&.ref,
        target_repository_id: repository.id,
        target_ref: pr.base&.ref,
        pr_number: pr.number,
        metadata: {
          "provenance" => "syrus_job_export",
          "ingest_mode" => "imported",
          "source_repo_slug" => pr.head&.repo&.full_name
        }
      )
      Rails.logger.info("[ExternalPrIngestions::SyrusJobExport] imported #{repository.slug}##{pr.number} as #{job.slug} (source not visible on this instance)")
      job
    end
  end
end
