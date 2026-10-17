class PollExternalOpenPrsJob < ApplicationJob
  include SkipIfPending
  include GithubPrPollHelpers

  queue_as :polling

  limits_concurrency to: 1, key: ->(repository_id, *) { "external_open_prs_poll:#{repository_id}" }

  SYRUS_BRANCH_PREFIX = "syrus/".freeze
  POLL_WIDE_ERROR_CLASSES = [
    Octokit::TooManyRequests,
    Octokit::Unauthorized,
    Octokit::Forbidden,
    Octokit::ServerError,
    Faraday::TimeoutError,
    Faraday::ConnectionFailed
  ].freeze

  def perform(repository_id)
    @repository = Repository.find_by(id: repository_id)
    return unless @repository && !@repository.archived? && @repository.external_pr_ingestion_enabled?
    return if @repository.github_api_rate_limited_for?

    @client = GithubClient.for(repository: @repository, user: @repository.user)
    @slug = @repository.slug

    open_prs = @client.list_open_pull_requests(@slug)
    @client.clear_api_blocked!
    existing_numbers = Job.tracked_pr_numbers_for(repository: @repository)

    open_prs.each do |pr|
      process_with_quarantine(pr, existing_numbers: existing_numbers)
    end
  end

  private

  def process_with_quarantine(pr, existing_numbers:)
    # A same-repo `syrus/`-prefixed branch is already tracked elsewhere
    # (the normal initial/retry workflow's own PR, or a promotion/hotfix-sync
    # ref-movement PR) via `Job#pr_number`/its own anchor Job — skip it here.
    # A *fork's* `syrus/`-prefixed branch is a different Syrus instance's
    # per-job or branch export (Story 8/9/10/11) and must reach
    # classification below, not be silently dropped.
    return if we_control_head?(pr) && pr.head.ref.start_with?(SYRUS_BRANCH_PREFIX)
    return if existing_numbers.include?(pr.number)

    ingest_pr!(pr)
    @repository.clear_poll_external_pr_error!(pr_number: pr.number)
  rescue *POLL_WIDE_ERROR_CLASSES
    raise
  rescue => e
    @repository.record_poll_external_pr_error!(pr_number: pr.number, error: e)
    Rails.logger.error(
      "[PollExternalOpenPrsJob] event=external_pr_ingestion_quarantined " \
      "repository=#{@slug} pr_number=#{pr.number} error_class=#{e.class.name} error_message=#{e.message.inspect}"
    )
  end

  def ingest_pr!(pr)
    fork_pr = !we_control_head?(pr)
    classification = PrProvenanceClassifier.classify(repository: @repository, pr: pr)

    Job.transaction do
      job = ExternalPrIngestions::Base.for(classification).ingest!(repository: @repository, pr: pr, fork_pr: fork_pr)
      Rails.logger.info("[PollExternalOpenPrsJob] ingested external PR ##{pr.number} for #{@slug} (fork=#{fork_pr}, provenance=#{classification}#{job ? ", job=#{job.slug}" : ""})")
    end
  end
end
