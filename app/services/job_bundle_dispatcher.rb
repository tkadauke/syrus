# Dispatches an epicless Job bundle: when a repository has a ready
# same-priority group of approved own-PR Jobs (LandingBundleAssembler's
# priority-tier scope), create the MergeTrain/MergeTrainMember rows (epic_id: nil,
# priority: <tier>), lock the member Jobs into :landing (claiming the
# repo's single landing slot), and start the merge_train Workflow on
# the tip member. Mirrors MergeTrainDispatcher's transactional
# locking pattern (app/services/merge_train_dispatcher.rb:24) so it
# races safely with the recurring landing queue tick. See the shared landing-retry feature.
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
    cancel_obsolete_automatic_visual_diffs!
    return if blocker_reason

    result = LandingBundleAssembler.for_repository(@repository)
    return unless result.ready?

    workflow = nil
    MergeTrain.transaction do
      members = result.members.map { |job| job.tap(&:lock!) }

      raise ActiveRecord::Rollback if landing_job_in_progress
      raise ActiveRecord::Rollback if active_member_work?(members)
      raise ActiveRecord::Rollback if active_member_lock?(members)
      raise ActiveRecord::Rollback if RebaseWorkflowSelector.active_for_jobs?(members)
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
        kind: "job_bundle",
        job: members.last,
        artifacts: { "merge_train_id" => train.id }.merge(fix_replay_artifacts_for(members))
      )
    end

    return unless workflow

    WorkUnits::Launcher.start!(workflow)
    workflow
  rescue WorkUnits::Launcher::LockConflict
    nil
  end

  def blocker_reason
    return "epicless job bundling is disabled" unless Feature.epicless_job_bundling_enabled?
    if (active = active_bundle_train)
      return "#{@repository.slug} already has an active job bundle (train ##{active.id}, #{active.state})"
    end
    return "#{@repository.slug} already has an active job bundle" if active_bundle_in_progress?

    if (landing_job = landing_job_in_progress)
      return "#{landing_job.slug} is already landing for #{@repository.slug}"
    end

    if !@bypass_cooldown && (failed_bundle = cooling_down_failure)
      return cooldown_reason(failed_bundle)
    end

    # Member-scoped checks run against the set that will actually land -- the
    # assembler's default scope, which already drops Jobs holding an active work
    # unit -- and never against a wider set.
    #
    # Two wider sets used to gate here, and both over-blocked. The
    # `potential_member_candidates` list is every approved epicless Job in the
    # tier with none of the assembler's eligibility filtering, and
    # `include_active: true` deliberately re-adds the Jobs the assembler just
    # dropped. Either way a Job the bundle would *exclude* could veto it, so one
    # Job carrying work that cannot finish -- a ci_failure repair blocked on
    # `ci_repair_safety` against a base SHA that will never be graded again --
    # stopped every other approved Job in the repository from landing,
    # indefinitely, while the landing queue reported only
    # `waiting_epicless_bundle` and recorded no failure anywhere.
    #
    # The wider candidate set is still worth consulting, but only to *explain* a
    # bundle that already cannot form -- never to prevent one that can. Naming
    # the work that removed a candidate is far more actionable than the
    # assembler's "fewer than N same-tier Jobs".
    readiness = LandingBundleAssembler.for_repository(@repository)
    return candidate_exclusion_reason || readiness.reason unless readiness.ready?

    return "landing queue is paused" if landing_queue_paused?(readiness.members)

    if (active_work = active_member_work(readiness.members))
      return active_member_work_reason(active_work)
    end

    if (active_lock = active_member_lock(readiness.members))
      return active_member_lock_reason(active_lock)
    end

    if (workflow = RebaseWorkflowSelector.active_for_jobs(readiness.members).order(:id).first)
      return "active rebase workflow #{workflow.slug} must finish before the job bundle starts"
    end
    if RebaseWorkflowSelector.active_for_jobs?(readiness.members)
      return "active rebase workflow must finish before the job bundle starts"
    end

    nil
  end

  private

  def cancel_obsolete_automatic_visual_diffs!
    VisualDiffSubmission.cancel_obsolete_automatic_work!(potential_member_candidates)
  end

  def active_bundle_in_progress?
    WorkUnits::Ownership.active_for_lock_key?(
      "landing:repository:#{@repository.id}",
      kinds: WorkDefinitions.family_kinds_for("job_bundle")
    ) || active_bundle_train.present?
  end

  # Named in the blocker reason because the bare message reads like a deadlock
  # when it is usually the opposite: a failed train is terminal and does not
  # block, so this fires when a *replacement* bundle is already running --
  # frequently one dispatched seconds after the failure that prompted the
  # rebuild. Saying which train is running turns "why is this stuck" into "it
  # is not stuck" at a glance.
  def active_bundle_train
    return @active_bundle_train if defined?(@active_bundle_train)

    @active_bundle_train = MergeTrain.active.where(repository_id: @repository.id, epic_id: nil).order(:id).last
  end

  def landing_job_in_progress
    if (unit = WorkUnits::Ownership.active_unit_for_lock_key("landing:repository:#{@repository.id}", kinds: WorkDefinitions.landing_lock_kinds))
      return unit.member_jobs.order(:id).first || unit.workflow&.job
    end

    Job.landing.where(repository_id: @repository.id).order(:id).first
  end

  # Reporting only. Called when no bundle can form, to say *why* a candidate was
  # dropped instead of only how many were left. Must never gate dispatch: these
  # same checks over a set wider than the actual members is exactly what let one
  # permanently blocked Job hold up every other approved Job in the repository.
  def candidate_exclusion_reason
    candidates = potential_member_candidates
    return if candidates.empty?

    return "landing queue is paused" if landing_queue_paused?(candidates)

    if (active_work = active_member_work(candidates))
      return active_member_work_reason(active_work)
    end

    if (workflow = RebaseWorkflowSelector.active_for_jobs(candidates).order(:id).first)
      return "active rebase workflow #{workflow.slug} must finish before the job bundle starts"
    end
    if RebaseWorkflowSelector.active_for_jobs?(candidates)
      return "active rebase workflow must finish before the job bundle starts"
    end

    if (active_lock = active_member_lock(candidates))
      return active_member_lock_reason(active_lock)
    end

    nil
  end

  def potential_member_candidates
    Job::PRIORITIES.each do |priority|
      candidates = @repository.jobs
        .approved
        .where(epic_id: nil, priority: priority)
        .where.not(kind: "external_pr")
        .to_a
        .group_by { |job| effective_owner_id(job) }
        .values
        .find { |group| group.size >= LandingBundleAssembler::Scopes::PriorityTier::MIN_BUNDLE_SIZE }

      return candidates if candidates
    end

    []
  end

  def effective_owner_id(job)
    job.owner_user_id.presence || job.user_id
  end

  def landing_queue_paused?(jobs)
    jobs.any? { |job| job.user.landing_paused? || job.owner_user&.landing_paused? }
  end

  def active_member_work?(members)
    active_member_work(members).present?
  end

  def active_member_lock?(members)
    active_member_lock(members).present?
  end

  def active_member_work(members)
    WorkUnits::Ownership
      .active_workflows_by_job_id(members.map(&:id))
      .values
      .compact
      .first
  end

  def active_member_work_reason(active_work)
    "active workflow #{active_work.slug} must finish before the job bundle starts"
  end

  def active_member_lock(members)
    members.each do |member|
      unit = WorkUnits::Ownership.active_unit_for_lock_key("job:#{member.id}")
      return unit if unit
    end

    nil
  end

  def active_member_lock_reason(unit)
    workflow = unit.workflow
    return active_member_work_reason(workflow) if workflow

    "active work unit WU-#{unit.id} must finish before the job bundle starts"
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
      LandingFailureHandler.merge_train_rebuild_required?(reason) ||
      reason.to_s.start_with?(MergeTrain::STALE_RUNTIME_FAILURE_REASON)
  end

  def fix_replay_artifacts_for(members)
    member_ids = members.map(&:id)
    source = MergeTrain
      .where(repository_id: @repository.id, epic_id: nil, state: "failed")
      .where.not(integration_branch: nil)
      .order(finished_at: :desc, id: :desc)
      .detect do |train|
        MergeTrainFixReplay.eligible_source?(train) &&
          train.members.order(:position).pluck(:job_id) == member_ids
      end

    MergeTrainFixReplay.source_artifacts_for(source)
  end

  def cooldown_reason(failed_bundle)
    remaining_seconds = [ failed_bundle.finished_at + RETRY_COOLDOWN - Time.current, 0 ].max
    remaining_minutes = (remaining_seconds / 60.0).ceil
    reason = failed_bundle.failure_reason.to_s.presence || "unclassified failure"
    "recent failed job bundle is cooling down for #{remaining_minutes}m: #{reason}"
  end
end
