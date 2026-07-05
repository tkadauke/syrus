class GracePeriodExpiryJob < ApplicationJob
  queue_as :default

  def perform(job_id)
    job = Job.find_by(id: job_id)
    return unless job

    # No-op if the grace period was cancelled (nil) or if the job was
    # already closed explicitly by the operator before we fired.
    return if job.grace_period_expires_at.nil?
    return if job.closed?

    # No-op if the grace period hasn't actually expired yet. This can
    # happen if the grace period was reset (e.g. on reopen + re-close)
    # and a second GracePeriodExpiryJob was enqueued that fires before
    # the updated expiry.
    return unless job.grace_period_expired?

    Rails.logger.info("[GracePeriodExpiryJob] Grace period expired for #{job.slug}; closing.")
    reason = grace_period_closure_reason(job)
    job.runs.active.find_each do |run|
      run.cancel! if run.may_cancel?
      run.save!
    end
    job.update!(grace_period_expires_at: nil)
    job.close_with_reason!(reason)

    delete_branch_if_needed(job)
  end

  private

  def grace_period_closure_reason(job)
    return "pr_closed" if job.needs_attention_reason == "upstream_pr_closed"

    "pr_closed"
  end

  def delete_branch_if_needed(job)
    return unless job.branch_name.present?

    client = GithubClient.for(repository: job.repository, user: job.user)
    client.delete_branch(job.repository.slug, job.branch_name)
    job.update_column(:branch_deleted_at, Time.current)
  rescue StandardError => e
    Rails.logger.warn("[GracePeriodExpiryJob] Branch deletion failed for #{job.slug}: #{e.message}")
  end
end
