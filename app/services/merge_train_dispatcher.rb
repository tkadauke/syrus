# Dispatches an Epic merge-train: when the Epic is ready (every open
# child approved, within size cap), create the MergeTrain + members,
# lock the member Jobs into :landing (claiming the repo's single landing
# slot), and start the merge_train Workflow on the tip member. Mirrors
# LandingQueueProcessor#land's transactional locking so it races safely
# with the recurring queue tick. See docs/plans/landing-merge-train.md.
class MergeTrainDispatcher
  # After a train fails (e.g. an unresolvable build conflict), don't
  # immediately re-dispatch — fail_landing reverts members to
  # :implemented and PollMergeStateJob may auto-re-approve them, which
  # would otherwise spin a doomed train every tick. Wait out a cooldown
  # so a genuinely-stuck Epic surfaces for an operator instead of
  # churning.
  RETRY_COOLDOWN = 30.minutes

  TRAIN_KIND = "merge_train".freeze
  MEMBER_CI_BLOCKER_KEYS = %w[
    ci_failure_in_progress
    ci_repair_no_effective_change
    pr_checks_failing
    pr_checks_failing_base_stale
    pr_checks_failing_base_unknown
    pr_checks_failing_inherited
    pr_checks_pending
  ].freeze

  def self.try_dispatch!(epic, bypass_cooldown: false) = new(epic, bypass_cooldown: bypass_cooldown).try_dispatch!
  def self.blocker_reason(epic, bypass_cooldown: false) = new(epic, bypass_cooldown: bypass_cooldown).blocker_reason

  def initialize(epic, bypass_cooldown: false)
    @epic = epic
    @bypass_cooldown = bypass_cooldown
  end

  def try_dispatch!
    return if blocker_reason

    result = LandingBundleAssembler.for_epic(@epic)
    return unless result.ready?

    workflow = nil
    MergeTrain.transaction do
      members = result.members.map { |job| job.tap(&:lock!) }
      delivery_policy = self.delivery_policy

      raise ActiveRecord::Rollback if landing_job_in_progress(job: members.last, policy: delivery_policy)
      raise ActiveRecord::Rollback if RebaseWorkflowSelector.active_for_jobs?(members)
      raise ActiveRecord::Rollback unless members.all?(&:eligible_for_landing_dispatch?)
      raise ActiveRecord::Rollback unless members.all? { |job| LandingApprovalGate.satisfied?(job, policy: delivery_policy) }
      raise ActiveRecord::Rollback if blocked_member_entry(members)
      base_branch = landing_branch_result_for(members).base_branch
      raise ActiveRecord::Rollback if base_branch.blank?

      train = MergeTrain.create!(
        epic: @epic,
        repository: @epic.repository,
        base_branch: base_branch
      )

      members.each_with_index do |job, index|
        job.landing_failure_reason = nil
        job.landing_failure_code = nil
        job.start_landing!
        job.save!
        MergeTrainMember.create!(merge_train: train, job: job, position: index)
      end

      workflow = WorkUnits::Launcher.instantiate(
        kind: "merge_train",
        job: members.last,
        artifacts: { "merge_train_id" => train.id }.merge(fix_replay_artifacts_for(members))
      )
    end

    return unless workflow

    WorkUnits::Launcher.start!(workflow)
    workflow
  end

  def blocker_reason
    return "landing queue is paused" if landing_queue_paused?
    return "waiting for Epic to release" unless @epic.releases_jobs_for_execution?
    return "#{@epic.slug} already has an active merge train" if active_train_in_progress?

    if (landing_job = landing_job_in_progress)
      return "#{landing_job.slug} is already landing for #{@epic.repository.slug}"
    end

    if !@bypass_cooldown && (failed_train = cooling_down_failure)
      return cooldown_reason(failed_train)
    end

    readiness = LandingBundleAssembler.for_epic(@epic)
    return readiness.reason unless readiness.ready?
    if (entry = blocked_member_entry(readiness.members))
      return "#{entry.job.slug} is blocked: #{entry.blocked_reason.fetch(:key)}"
    end
    landing_branch_result = landing_branch_result_for(readiness.members)
    return landing_branch_result.reason unless landing_branch_result.ok?

    if (workflow = RebaseWorkflowSelector.active_for_jobs(readiness.members).order(:id).first)
      return "active rebase workflow #{workflow.slug} must finish before the merge train starts"
    end
    if RebaseWorkflowSelector.active_for_jobs?(readiness.members)
      return "active rebase workflow must finish before the merge train starts"
    end

    blockers = landing_unit_blockers_for(readiness.members)
    return "stack dependencies not ready: #{blockers.map(&:slug).join(", ")}" if blockers.any?

    if (held = held_lock_reason(readiness.members))
      return held
    end

    nil
  end

  private

  def blocked_member_entry(members)
    LandingQueueProcessor
      .entries(Job.where(id: members.map(&:id)))
      .find { |entry| MEMBER_CI_BLOCKER_KEYS.include?(entry.blocked_reason&.dig(:key)) }
  end

  # Same blind spot JobBundleDispatcher had: the launcher refuses a train whose
  # locks another WorkUnit holds, and blocker_reason -- the reason the landing
  # queue shows an operator -- never asked who held them.
  def held_lock_reason(members)
    return nil if members.empty?

    definition = WorkDefinitions.for(TRAIN_KIND)
    keys = definition.lock_keys_for(job: members.last, member_jobs: members, artifacts: {})
    key, owner = WorkUnits::Ownership.blocking_lock_owner(keys)
    return nil unless owner

    holder = owner.workflow&.slug.presence || "WU-#{owner.id}"
    "#{owner.kind} #{holder} holds #{key}; the merge train starts once it releases"
  rescue WorkDefinitions::UnknownKind
    nil
  end

  def landing_queue_paused?
    @epic.user.landing_paused? || @epic.owner_user&.landing_paused?
  end

  def active_train_in_progress?
    MergeTrain.active.where(epic_id: @epic.id).exists? ||
      WorkUnits::Ownership.active_for_epic?(
        @epic,
        kinds: WorkDefinitions.family_kinds_for("merge_train")
      )
  end

  def landing_job_in_progress(job: landing_lock_job, policy: delivery_policy)
    lock_key = WorkDefinitions.landing_lock_key_for(job, policy: policy)
    if lock_key && (unit = WorkUnits::Ownership.active_unit_for_lock_key(lock_key, kinds: WorkDefinitions.landing_lock_kinds))
      return unit.member_jobs.order(:id).first || unit.workflow&.job
    end

    return unless lock_key

    Job.landing.where(repository_id: @epic.repository_id).order(:id).detect do |landing_job|
      WorkDefinitions.landing_lock_key_for(landing_job, policy: policy) == lock_key
    end
  end

  # A train takes one landing slot, so its members must resolve to one branch.
  # If they disagree, leave the lock lookup alone and let the branch resolver
  # report the configuration error instead of arbitrarily choosing a member.
  def landing_lock_job
    members = @epic.jobs.approved.to_a
    return if members.empty?

    branches = members.map { |member| delivery_policy.job_landing_branch(member).presence || @epic.repository.default_branch }.uniq
    members.last if branches.one?
  end

  def delivery_policy
    @delivery_policy ||= DeliveryPolicy.for(repository: @epic.repository)
  end

  def cooling_down_failure
    MergeTrain
      .where(epic_id: @epic.id, state: "failed")
      .where("finished_at > ?", RETRY_COOLDOWN.ago)
      .order(finished_at: :desc)
      .find { |train| !skip_cooldown_failure?(train) }
  end

  def skip_cooldown_failure?(train)
    if train.failure_code.present?
      return LandingFailureCode.resolve(train.failure_code)&.skip_merge_train_cooldown? || false
    end

    # Compatibility for MergeTrain rows written before failure_code existed.
    LandingFailureCode.legacy_from_reason(train.failure_reason)&.skip_merge_train_cooldown? || false
  end

  def fix_replay_artifacts_for(members)
    source = MergeTrain
      .where(epic_id: @epic.id, state: "failed")
      .where.not(integration_branch: nil)
      .order(finished_at: :desc, id: :desc)
      .detect do |train|
        MergeTrainFixReplay.eligible_source?(train) &&
          train.members.order(:position).pluck(:job_id) == members.map(&:id)
      end

    MergeTrainFixReplay.source_artifacts_for(source)
  end

  def landing_unit_blockers_for(members)
    unit = LandingQueueProcessor.landing_units(Job.where(id: members.map(&:id))).first
    return [] unless unit

    unit.blocker_jobs
  end

  def landing_branch_result_for(members)
    MergeTrains::LandingBranchResolver.call(repository: @epic.repository, members: members)
  end

  def cooldown_reason(failed_train)
    remaining_seconds = [ failed_train.finished_at + RETRY_COOLDOWN - Time.current, 0 ].max
    remaining_minutes = (remaining_seconds / 60.0).ceil
    reason = failed_train.failure_reason.to_s.presence || "unclassified failure"
    "recent failed merge train is cooling down for #{remaining_minutes}m: #{reason}"
  end
end
