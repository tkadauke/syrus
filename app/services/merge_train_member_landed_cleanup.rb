# What every path that lands a merge-train member does after the landing is
# final: comment on and close the member's PR, retarget any stacked child PRs
# onto the train's base, delete the member branch and stamp it deleted.
#
# Steps::MergeTrainLand does this inline for members it verifies; the
# reconciler's member repair and MergeTrainFailureHandler's self-heal land a
# member outside that step and call this, so a member's cleanup does not
# depend on which path landed it (formal/SyrusModel/MemberLandingCleanup.lean).
#
# Best-effort: the landing is already final, so a GitHub error is logged and
# swallowed rather than undoing anything.
class MergeTrainMemberLandedCleanup
  def self.call(...) = new(...).call

  def initialize(client:, train:, job:, log:, integration_pr: nil, now: Time.current)
    @client = client
    @train = train
    @job = job
    @log = log
    @integration_pr = integration_pr
    @now = now
  end

  def call
    reconcile_pull_request
    clean_up_branch
  end

  private

  attr_reader :client, :train, :job, :log

  def reconcile_pull_request
    MergeTrainMemberPrReconciler.call(
      client: client, repository: train.repository, train: train, member_job: job,
      integration_pr: @integration_pr, log: log
    )
  rescue StandardError => e
    Rails.logger.warn("[MergeTrainMemberLandedCleanup] could not reconcile PR for #{job.slug}: #{e.class}: #{e.message}")
  end

  def clean_up_branch
    return if job.branch_name.blank?

    StackChildPullRequestRetargeter.call(
      client: client, parent: job, base: train.base_branch,
      skip_job_ids: train.members.map(&:job_id), log: ->(message, **) { log.call(message) }
    )
    job.update_column(:branch_deleted_at, @now) if client.delete_branch(train.repository.slug, job.branch_name)
  rescue StandardError => e
    Rails.logger.warn("[MergeTrainMemberLandedCleanup] branch cleanup for #{job.slug} failed: #{e.class}: #{e.message}")
  end
end
