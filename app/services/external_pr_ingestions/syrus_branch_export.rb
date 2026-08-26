module ExternalPrIngestions
  # Story 10/11: a whole Syrus development branch exported as one PR (Bob's
  # PR). First iteration keeps this coarse per the plan's explicit scope: one
  # umbrella Job wrapped in one Epic as a single review unit, no child-Job
  # splitting — the Epic gives the maintainer a review surface, not a
  # decomposition. The umbrella Job still runs the ordinary
  # `external_pr_ingest` grade loop: a whole exported branch is exactly the
  # unverified-diff case that loop exists for.
  class SyrusBranchExport < Base
    def ingest!(repository:, pr:, fork_pr:)
      epic = Epic.create!(
        repository: repository,
        user: repository.user,
        title: "Branch export: #{pr.head&.repo&.full_name}:#{pr.head&.ref} (##{pr.number})",
        description: "Umbrella review for a Syrus development-branch export ingested from " \
                      "#{pr.head&.repo&.full_name}:#{pr.head&.ref}.\n\n#{pr.html_url}".strip
      )

      job = JobFactory.create!(repository: repository, pr: pr, fork_pr: fork_pr, epic_id: epic.id)
      JobPrLink.record!(
        job: job,
        role: JobPrLink::ROLE_EXTERNAL_INGEST,
        source_repository_id: nil,
        source_ref: pr.head&.ref,
        target_repository_id: repository.id,
        target_ref: pr.base&.ref,
        pr_number: pr.number,
        metadata: {
          "provenance" => "syrus_branch_export",
          "source_repo_slug" => pr.head&.repo&.full_name
        }
      )
      Rails.logger.info("[ExternalPrIngestions::SyrusBranchExport] ingested #{repository.slug}##{pr.number} as #{job.slug} under Epic ##{epic.number}")
      job
    end
  end
end
