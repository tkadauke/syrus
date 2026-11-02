class PullRequestMergeCloser
  def self.call(job:, landed_sha: nil)
    new(job: job, landed_sha: landed_sha).call
  end

  def initialize(job:, landed_sha: nil)
    @job = job
    @landed_sha = landed_sha
  end

  def call
    closed = @job.with_lock do
      next false unless @job.open?

      @job.runs.active.find_each do |run|
        run.cancel! if run.may_cancel?
        run.save!
      end

      @job.update!(grace_period_expires_at: nil, landed_sha: @landed_sha.presence || @job.landed_sha)
      @job.close_with_reason!("pr_merged")
      true
    end

    delete_branch if closed
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
