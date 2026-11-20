class PullRequestMergeCloser
  def self.call(job:, landed_sha: nil)
    new(job: job, landed_sha: landed_sha).call
  end

  def initialize(job:, landed_sha: nil)
    @job = job
    @landed_sha = landed_sha
  end

  # Closing goes through JobClosure outside the Job lock: it cancels the Job's
  # other Workflows (Workflow lock, then Job), and an active landing Workflow
  # that merged this PR keeps it until it finishes. The branch is deleted only
  # when the Job closed here; a deferring landing still owns it.
  def call
    recorded = @job.with_lock do
      next false unless @job.open?

      @job.update!(grace_period_expires_at: nil, landed_sha: @landed_sha.presence || @job.landed_sha)
      true
    end
    return unless recorded

    delete_branch if JobClosure.request!(@job, "pr_merged") == :closed
  end

  private

  def delete_branch
    return if @job.branch_name.blank? || @job.branch_deleted_at.present?

    client = GithubClient.for(repository: @job.repository, user: @job.user)
    client.delete_branch(@job.repository.slug, @job.branch_name)
    @job.update_column(:branch_deleted_at, Time.current)
  rescue => e
    Rails.logger.warn("[PullRequestMergeCloser] #{@job.slug}: could not delete fork branch — #{e.message}")
  end
end
