# Re-triggers a failed landing attempt (Epic merge-train or epicless job
# bundle) by re-approving Jobs that fell back to :implemented when the
# train failed (fail_landing clears approval), optionally first recovering
# members of a specific failed MergeTrain back from :failed to
# :implemented before re-approval. Both landing shapes already flow
# through the identical Workflows::MergeTrain step chain and
# MergeTrainFailureHandler; the only real difference is which Jobs are in
# scope for recovery/re-approval and which dispatcher restarts the train,
# so that lives here as a Scope strategy (LandingRetrier::Scopes::Epic /
# ::Bundle) rather than as two near-duplicate classes. See the relevant change.
class LandingRetrier
  Result = Data.define(:reapproved_jobs, :recovered_jobs, :workflow) do
    def jobs = reapproved_jobs
    def any? = reapproved_jobs.any? || recovered_jobs.any? || workflow.present?
  end

  def self.call(scope) = new(scope).call
  def self.rebuild_merge_train!(scope) = new(scope).rebuild_merge_train!

  # Epic-backed scope: EpicLandingRetrier's former `.call` entry point.
  # The bulk "Retry landing" affordance for an Epic -- one action instead
  # of re-approving N children individually.
  def self.for_epic(epic, by_user: nil) = call(Scopes::Epic.new(epic, by_user: by_user))

  # Epic-backed scope: EpicLandingRetrier's former `.rebuild_merge_train!`
  # entry point.
  def self.rebuild_epic_merge_train!(epic, by_user: nil, source_train:)
    rebuild_merge_train!(Scopes::Epic.new(epic, by_user: by_user, source_train: source_train))
  end

  # Bundle-backed scope: JobBundleRetrier's former `.rebuild_merge_train!`
  # entry point. Bundle-backed MergeTrain rows have no Epic, so recovery is
  # scoped to the source train's member Jobs rather than an Epic's implemented
  # children.
  def self.rebuild_job_bundle!(repository, by_user: nil, source_train:)
    rebuild_merge_train!(Scopes::Bundle.new(repository, by_user: by_user, source_train: source_train))
  end

  def initialize(scope)
    @scope = scope
  end

  def call
    result = reapprove_candidates

    # Kick the queue so the train dispatches without waiting for the
    # next recurring tick.
    LandingQueueProcessor.try_land! if result.reapproved_jobs.any?
    result.reapproved_jobs
  end

  def rebuild_merge_train!
    result = reapprove_candidates
    workflow = @scope.dispatch!

    Result.new(
      reapproved_jobs: result.reapproved_jobs,
      recovered_jobs: result.recovered_jobs,
      workflow: workflow
    )
  end

  private

  def reapprove_candidates
    reapproved = []
    recovered = []

    Job.transaction do
      recovered = recover_failed_train_members

      @scope.reapproval_candidates.each do |job|
        job.lock!
        next unless job.implemented?
        next unless job.pr_number.present?
        next unless job.may_approve?

        job.approve!(via: "operator", by_user: @scope.by_user)
        job.save!
        reapproved << job
      end
    end

    Result.new(reapproved_jobs: reapproved, recovered_jobs: recovered, workflow: nil)
  end

  def recover_failed_train_members
    @scope.recoverable_members.filter_map do |job|
      job.lock!
      next unless job.failed?
      next unless job.pr_number.present?

      job.assign_attributes(
        state: "implemented",
        approved_at: nil,
        approved_via: nil,
        approved_by_user_id: nil,
        approval_evidence: {},
        landing_failure_reason: nil
      )
      job.job_approvals.destroy_all
      job.save!
      job
    end
  end
end
