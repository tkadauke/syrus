class PollExternalOpenPrsJob < ApplicationJob
  include GithubPrPollHelpers

  queue_as :polling

  limits_concurrency to: 1, key: ->(repository_id, *) { "external_open_prs_poll:#{repository_id}" }

  SYRUS_BRANCH_PREFIX = "syrus/".freeze

  def perform(repository_id)
    @repository = Repository.find_by(id: repository_id)
    return unless @repository && !@repository.archived? && @repository.external_pr_ingestion_enabled?

    @client = GithubClient.for(repository: @repository, user: @repository.user)
    @slug = @repository.slug

    open_prs = @client.list_open_pull_requests(@slug)
    existing_numbers = Job.tracked_pr_numbers_for(repository: @repository)

    open_prs.each do |pr|
      # A same-repo `syrus/`-prefixed branch is already tracked elsewhere
      # (the normal initial/retry workflow's own PR, or a promotion/hotfix-sync
      # ref-movement PR) via `Job#pr_number`/its own anchor Job — skip it here.
      # A *fork's* `syrus/`-prefixed branch is a different Syrus instance's
      # per-job or branch export (Story 8/9/10/11) and must reach
      # classification below, not be silently dropped.
      next if we_control_head?(pr) && pr.head.ref.start_with?(SYRUS_BRANCH_PREFIX)
      next if existing_numbers.include?(pr.number)

      ingest_pr!(pr)
    end
  end

  private

  def ingest_pr!(pr)
    fork_pr = !we_control_head?(pr)
    classification = PrProvenanceClassifier.classify(repository: @repository, pr: pr)

    Job.transaction do
      job = ExternalPrIngestions::Base.for(classification).ingest!(repository: @repository, pr: pr, fork_pr: fork_pr)
      Rails.logger.info("[PollExternalOpenPrsJob] ingested external PR ##{pr.number} for #{@slug} (fork=#{fork_pr}, provenance=#{classification}#{job ? ", job=#{job.slug}" : ""})")
    end
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
    Rails.logger.warn("[PollExternalOpenPrsJob] skipped PR ##{pr.number} for #{@slug}: #{e.message}")
  end
end
