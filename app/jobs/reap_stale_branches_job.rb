class ReapStaleBranchesJob < ApplicationJob
  include SkipIfPending

  queue_as :cleanup

  CLOSED_GRACE_PERIOD = 23.hours
  MAX_BRANCHES_PER_RUN = 100

  def perform(dry_run: false)
    scope = Job.where.not(branch_name: nil)
               .where(state: "closed")
               .where(branch_deleted_at: nil)
               .where(finished_at: ..CLOSED_GRACE_PERIOD.ago)
               .order(:branch_cleanup_attempted_at, :finished_at, :id)
               .limit(MAX_BRANCHES_PER_RUN)

    scope.includes(:repository, :user).each do |job|
      job.update_column(:branch_cleanup_attempted_at, Time.current) unless dry_run
      unless dry_run
        snapshot = DiffReviewVersions::FinalSnapshot.materialize(job: job, user: job.user)
        unless snapshot.materialized?
          Rails.logger.warn("[ReapStaleBranchesJob] skipped #{job.repository.slug}@#{job.branch_name}: final review snapshot unavailable (#{snapshot.reason})")
          next
        end
      end

      result = BranchCleanup::Reconciler.new(
        repository: job.repository, user: job.user, branch_name: job.branch_name,
        recorded_sha: job.head_sha, require_recorded_sha: true,
        owner_job: job, dry_run: dry_run
      ).call
      job.update_column(:branch_deleted_at, Time.current) if result.deleted? && !dry_run
    rescue => e
      Rails.logger.warn("[ReapStaleBranchesJob] failed to delete #{job.repository.slug}@#{job.branch_name}: #{e.message}")
    end
  end
end
