class PollExternalOpenPrsJob < ApplicationJob
  queue_as :default

  limits_concurrency to: 1, key: ->(repository_id, *) { "external_open_prs_poll:#{repository_id}" }

  SYRUS_BRANCH_PREFIX = "syrus/".freeze

  def perform(repository_id)
    @repository = Repository.find_by(id: repository_id)
    return unless @repository && !@repository.archived? && @repository.external_pr_ingestion_enabled?

    @client = GithubClient.for(repository: @repository, user: @repository.user)
    @slug = @repository.slug

    open_prs = @client.list_open_pull_requests(@slug)
    existing_numbers = Job.where(repository: @repository)
                          .where.not(external_pr_number: nil)
                          .pluck(:external_pr_number).to_set

    open_prs.each do |pr|
      next if pr.head.ref.start_with?(SYRUS_BRANCH_PREFIX)
      next if existing_numbers.include?(pr.number)

      ingest_pr!(pr)
    end
  end

  private

  def ingest_pr!(pr)
    Job.create!(
      user: @repository.user,
      repository: @repository,
      kind: "external_pr",
      state: "implemented",
      external_pr_number: pr.number,
      external_pr_author: pr.user&.login,
      issue_title: pr.title
    )
    Rails.logger.info("[PollExternalOpenPrsJob] ingested external PR ##{pr.number} for #{@slug}")
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
    Rails.logger.warn("[PollExternalOpenPrsJob] skipped PR ##{pr.number} for #{@slug}: #{e.message}")
  end
end
