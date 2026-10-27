class ReconcileIntegrationBranchesJob < ApplicationJob
  include SkipIfPending

  queue_as :cleanup

  GRACE_PERIOD = 23.hours
  MAX_BRANCHES_PER_RUN = 100

  def perform(dry_run: false)
    candidates.limit(MAX_BRANCHES_PER_RUN).includes(:repository, members: { job: :user }).each do |train|
      train.update_column(:branch_cleanup_attempted_at, Time.current) unless dry_run
      user = train.members.first&.job&.user || train.repository.user
      result = BranchCleanup::Reconciler.new(
        repository: train.repository, user: user, branch_name: train.integration_branch,
        recorded_sha: train.integration_sha, dry_run: dry_run
      ).call
      train.update_column(:branch_deleted_at, Time.current) if result.deleted? && !dry_run
    end
  end

  private

  def candidates
    MergeTrain.where(state: MergeTrain::TERMINAL_STATES, branch_deleted_at: nil)
              .where.not(integration_branch: nil)
              .where(finished_at: ..GRACE_PERIOD.ago)
              .order(:branch_cleanup_attempted_at, :finished_at, :id)
  end
end
