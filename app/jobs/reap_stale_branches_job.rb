class ReapStaleBranchesJob < ApplicationJob
  include SkipIfPending

  queue_as :cleanup

  CLOSED_GRACE_PERIOD = 23.hours

  def perform
    scope = Job.where.not(branch_name: nil)
               .where(state: "closed")
               .where(branch_deleted_at: nil)
               .where("finished_at < ?", CLOSED_GRACE_PERIOD.ago)

    scope.includes(:repository).find_each do |job|
      client = GithubClient.for(repository: job.repository, user: job.user)
      job.update_column(:branch_deleted_at, Time.current) if client.delete_branch(job.repository.slug, job.branch_name)
    rescue => e
      Rails.logger.warn("[ReapStaleBranchesJob] failed to delete #{job.repository.slug}@#{job.branch_name}: #{e.message}")
    end
  end
end
