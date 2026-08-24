# Re-triggers a failed epicless job bundle. Bundle-backed MergeTrain rows
# have no Epic, so they cannot use EpicLandingRetrier's sibling approval
# checks; recovery is scoped to the source train's member Jobs.
class JobBundleRetrier
  def self.rebuild_merge_train!(repository, by_user: nil, source_train:)
    new(repository, by_user: by_user, source_train: source_train).rebuild_merge_train!
  end

  Result = Data.define(:reapproved_jobs, :recovered_jobs, :workflow) do
    def jobs = reapproved_jobs
    def any? = reapproved_jobs.any? || recovered_jobs.any? || workflow.present?
  end

  def initialize(repository, by_user: nil, source_train:)
    @repository = repository
    @by_user = by_user
    @source_train = source_train
  end

  def rebuild_merge_train!
    result = reapprove_members
    workflow = JobBundleDispatcher.try_dispatch!(@repository, bypass_cooldown: true)

    Result.new(
      reapproved_jobs: result.reapproved_jobs,
      recovered_jobs: result.recovered_jobs,
      workflow: workflow
    )
  end

  private

  def reapprove_members
    reapproved = []
    recovered = []

    Job.transaction do
      recovered = recover_failed_train_members

      member_jobs.each do |job|
        job.lock!
        next unless job.implemented?
        next unless job.pr_number.present?
        next unless job.may_approve?

        job.approve!(via: "operator", by_user: @by_user)
        job.save!
        reapproved << job
      end
    end

    Result.new(reapproved_jobs: reapproved, recovered_jobs: recovered, workflow: nil)
  end

  def recover_failed_train_members
    member_jobs.filter_map do |job|
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

  def member_jobs
    @member_jobs ||= @source_train.members.includes(:job).map(&:job)
  end
end
