# Dispatches an epicless Job bundle: when a repository has a ready
# same-priority group of approved own-PR Jobs (JobBundleAssembler),
# create the MergeTrain/MergeTrainMember rows (epic_id: nil,
# priority: <tier>), lock the member Jobs into :landing (claiming the
# repo's single landing slot), and start the merge_train Workflow on
# the tip member. Mirrors MergeTrainDispatcher's transactional
# locking pattern (app/services/merge_train_dispatcher.rb:24) so it
# races safely with the recurring landing queue tick. See EPIC-246.
#
# Called from LandingQueueProcessor#try_land! and #call once a Job has
# enough same-tier epicless siblings (LandingQueueProcessor.bundle_eligible_epicless_job?).
class JobBundleDispatcher
  # Same cooldown rationale as MergeTrainDispatcher: don't immediately
  # re-dispatch after a failed bundle, so a genuinely-stuck group of
  # Jobs surfaces for an operator instead of churning every tick.
  RETRY_COOLDOWN = MergeTrainDispatcher::RETRY_COOLDOWN

  def self.try_dispatch!(repository, bypass_cooldown: false) = new(repository, bypass_cooldown: bypass_cooldown).try_dispatch!
  def self.blocker_reason(repository, bypass_cooldown: false) = new(repository, bypass_cooldown: bypass_cooldown).blocker_reason

  def initialize(repository, bypass_cooldown: false)
    @repository = repository
    @bypass_cooldown = bypass_cooldown
  end

  def try_dispatch!
    return if blocker_reason

    result = JobBundleAssembler.call(@repository)
    return unless result.ready?

    workflow = nil
    MergeTrain.transaction do
      members = result.members.map { |job| job.tap(&:lock!) }

      raise ActiveRecord::Rollback if Job.landing.where(repository_id: @repository.id).exists?
      raise ActiveRecord::Rollback if RebaseWorkflowSelector.active_for_jobs(members).exists?
      raise ActiveRecord::Rollback unless members.all? { |job| job.approved? && job.may_start_landing? }

      train = MergeTrain.create!(
        repository: @repository,
        base_branch: @repository.default_branch,
        priority: result.priority
      )

      members.each_with_index do |job, index|
        job.landing_failure_reason = nil
        job.start_landing!
        job.save!
        MergeTrainMember.create!(merge_train: train, job: job, position: index)
      end

      workflow = WorkUnits::Launcher.instantiate(
        kind: "merge_train",
        job: members.last,
        artifacts: { "merge_train_id" => train.id }
      )
    end

    return unless workflow

    StepDispatcher.start_workflow(workflow)
    workflow
  end

  def blocker_reason
    return "epicless job bundling is disabled" unless Feature.epicless_job_bundling_enabled?
    return "#{@repository.slug} already has an active job bundle" if active_bundle_in_progress?

    if (landing_job = landing_job_in_progress)
      return "#{landing_job.slug} is already landing for #{@repository.slug}"
    end

    if !@bypass_cooldown && (failed_bundle = cooling_down_failure)
      return cooldown_reason(failed_bundle)
    end

    readiness = JobBundleAssembler.call(@repository)
    return readiness.reason unless readiness.ready?

    if (workflow = RebaseWorkflowSelector.active_for_jobs(readiness.members).order(:id).first)
      return "active rebase workflow #{workflow.slug} must finish before the job bundle starts"
    end

    nil
  end

  private

  def active_bundle_in_progress?
    MergeTrain.active.where(repository_id: @repository.id, epic_id: nil).exists?
  end

  def landing_job_in_progress
    Job.landing.where(repository_id: @repository.id).order(:id).first
  end

  # Mirrors MergeTrainDispatcher#cooling_down_failure: transient
  # landing-start blockers and stale-base rebuild failures don't count
  # against the cooldown, since those aren't "genuinely stuck" bundles
  # — the approved members re-enter the queue and Syrus can retry as
  # soon as the transient blocker clears. Reuses the same reason
  # classifiers MergeTrainFailureHandler and LandingFailureHandler
  # already use instead of re-deriving the LIKE patterns.
  def cooling_down_failure
    MergeTrain
      .where(repository_id: @repository.id, epic_id: nil, state: "failed")
      .where("finished_at > ?", RETRY_COOLDOWN.ago)
      .order(finished_at: :desc)
      .find { |train| !transient_failure?(train.failure_reason) }
  end

  def transient_failure?(reason)
    LandingQueueReentry.landing_start_blocker?(reason) ||
      LandingFailureHandler.merge_train_rebuild_required?(reason)
  end

  def cooldown_reason(failed_bundle)
    remaining_seconds = [ failed_bundle.finished_at + RETRY_COOLDOWN - Time.current, 0 ].max
    remaining_minutes = (remaining_seconds / 60.0).ceil
    reason = failed_bundle.failure_reason.to_s.presence || "unclassified failure"
    "recent failed job bundle is cooling down for #{remaining_minutes}m: #{reason}"
  end
end
