class WorkUnit < ApplicationRecord
  STATES = %w[queued blocked running succeeded failed cancelled].freeze
  # A WorkUnit is finished only in these. Note `blocked` is NOT terminal
  # here even though Workflow#terminal? counts it: a blocked Workflow is
  # waiting on something external, not done.
  TERMINAL_STATES = %w[succeeded failed cancelled].freeze
  PREEMPTION_REASON_MAX_LENGTH = 64

  # Reasons that mean "this Job is simply waiting in line on an
  # unfinished dependency" — the "Blocked" smart folder's territory,
  # not "Paused".
  DEPENDENCY_BLOCKED_REASONS = %w[
    dependency_failed
    dependency_approval_withdrawn
    stack_dependencies_not_ready
    stack_fan_in_base_unavailable
    job_not_ready_for_execution
  ].freeze

  BLOCKED_REASONS = %w[
    admission_control
    provider_availability
    manual_pause
    main_branch_health
    dependency_failed
    dependency_approval_withdrawn
    stack_dependencies_not_ready
    stack_fan_in_base_unavailable
    job_not_ready_for_execution
    urgent_job_active
    epic_wide_workflow_active
    epic_sibling_implementation_active
    resource_safety
    ci_repair_safety
    ci_repair_disabled
    active_work_lock
    patient_rebase_waiting_for_active_workflow
    agent_cannot_proceed
    auto_retry_backoff
    no_capable_worker
    visual_diff_obsolete
    coworker_turn_in_flight
    preempted
  ].freeze

  # Reasons that cannot clear by waiting: they clear only when an operator
  # changes the fleet or the configuration. A unit parked on one of these is
  # not "about to run", so it must not keep holding the landing slot — that
  # slot is the repository-wide mutex every landing path checks, and squatting
  # it starves every other approved Job in the repository indefinitely while
  # nothing is recorded as failed.
  #
  # Deliberately an allowlist. Reasons that resolve on their own (backoff,
  # lock contention, dependencies finishing) keep their locks, because they
  # genuinely are about to run and releasing would let a later landing cut
  # ahead of them.
  # `agent_cannot_proceed` belongs here too: a started landing whose repair
  # agent reported it cannot proceed waits for a person or the agent to act,
  # never for time to pass.
  # `manual_pause` too (NY27): a person paused it and only a person unpauses
  # it. Unpausing takes the slot back, or waits its turn when another landing
  # took it meanwhile (JobManualPause.unpause!).
  EXTERNALLY_CLEARED_BLOCKED_REASONS = %w[
    agent_cannot_proceed
    ci_repair_disabled
    manual_pause
    no_capable_worker
  ].freeze

  # Only the repository-wide landing slot is surrendered. Job- and epic-scoped
  # locks stay held: they exist to stop a second attempt at the *same* work,
  # which is still correct while this unit is parked.
  LANDING_LOCK_KEY_PREFIX = "landing:".freeze

  # Genuine pause reasons — a human paused the Job (manual_pause), or the
  # agent provider is unavailable/over quota (provider_availability). This
  # is a deliberate allowlist, not `BLOCKED_REASONS - DEPENDENCY_BLOCKED_REASONS`:
  # every other blocked reason (admission_control, resource_safety, locks,
  # backoff, etc.) is normal scheduling contention already surfaced via the
  # "Queued" folder's blocked badge, not a genuine pause. Keeping this an
  # allowlist means a newly added BLOCKED_REASONS value defaults to NOT
  # showing under "Paused" unless explicitly opted in here.
  PAUSE_BLOCKED_REASONS = %w[
    manual_pause
    provider_availability
  ].freeze

  belongs_to :work_intent
  belongs_to :repository, optional: true
  belongs_to :source_repository, class_name: "Repository", optional: true
  belongs_to :target_repository, class_name: "Repository", optional: true
  belongs_to :workflow, optional: true, inverse_of: :work_unit
  belongs_to :parent_work_unit, class_name: "WorkUnit", optional: true
  belongs_to :preempted_by_work_unit, class_name: "WorkUnit", optional: true
  belongs_to :blocked_by_user, class_name: "User", optional: true

  has_many :child_work_units, class_name: "WorkUnit", foreign_key: :parent_work_unit_id, dependent: nil, inverse_of: :parent_work_unit
  has_many :work_unit_members, dependent: nil
  has_many :member_jobs, through: :work_unit_members, source: :job
  has_many :work_unit_locks, dependent: nil

  before_validation :normalize_blocked_details
  before_validation :sync_active_dedup_key

  validates :kind, :state, :scope_type, presence: true
  validates :state, inclusion: { in: STATES }
  validates :blocked_reason, inclusion: { in: BLOCKED_REASONS }, allow_blank: true

  STATES.each do |state_name|
    define_method("#{state_name}?") { state == state_name }
  end

  def terminal?
    succeeded? || failed? || cancelled?
  end

  def active?
    queued? || blocked? || running?
  end

  def definition
    WorkDefinitions.for(kind)
  end

  def slug
    "WU-#{id || 'new'}"
  end

  # `blocked_at` measures the block episode, not the last time anything
  # touched the row. Re-checks (main-branch health re-polls, admission
  # control on every dispatcher tick) call block! again with the same
  # reason; carrying the original timestamp forward is what keeps a
  # thirteen-hour block from reporting five minutes. A reason change starts
  # a new episode.
  def block!(reason:, blocked_until: nil, details: {}, user: nil)
    transaction do
      reactivate_work_intent!
      continuing = blocked? && blocked_reason == reason.to_s && blocked_at.present?
      update!(
        state: "blocked",
        blocked_reason: reason,
        blocked_at: continuing ? blocked_at : Time.current,
        blocked_until: blocked_until,
        blocked_details: details || {},
        blocked_by_user: user
      )
      release_landing_locks! if EXTERNALLY_CLEARED_BLOCKED_REASONS.include?(reason.to_s)
      release_landing_locks! if prestart_landing_block?
    end
  end

  # Blocked on purpose, with something already set to wake it: a pause
  # (lifted by the operator or the provider recovering), or a gate whose own
  # recheck is still due at blocked_until. Resuming such a unit early is only
  # refused again (formal/SyrusModel/Agreement.lean, F16 and F40).
  def deliberate_wait?
    return false unless blocked?

    PAUSE_BLOCKED_REASONS.include?(blocked_reason.to_s) || blocked_until&.future? || false
  end

  def unblock!
    transaction do
      reactivate_work_intent!
      update!(
        state: "queued",
        blocked_reason: nil,
        blocked_at: nil,
        blocked_until: nil,
        blocked_details: {},
        blocked_by_user: nil
      )
    end
  end

  # A block can be projected after a Workflow has already started (for
  # example, while admitting a later phase). Clearing that block must restore
  # the runtime state instead of making the WorkUnit look startable again.
  # A queued unit also reclaims any surrendered landing lock before it becomes
  # startable, so its first Run can never bypass repository mutual exclusion.
  def resume_for_workflow!
    if Workflow.exists?(id: workflow_id, state: "running")
      mark_running!
    else
      transaction do
        ensure_active_locks!
        unblock!
      end
    end
  end

  def mark_running!
    transaction do
      lock_definition_jobs!
      reactivate_work_intent!
      ensure_active_locks!
      update!(
        state: "running",
        started_at: started_at || Time.current,
        finished_at: nil,
        blocked_reason: nil,
        blocked_at: nil,
        blocked_until: nil,
        blocked_details: {},
        blocked_by_user: nil
      )
    end
  end

  def lock_definition_jobs!
    # With their Epics, top down (NY40): a Job state change this transaction
    # makes refreshes its Epic.
    Lineage.lock_all!(definition_jobs)
  end

  # Every Job this unit's definition covers: its members, its Workflow's Job
  # and a Job scope.
  def definition_jobs
    job_ids = work_unit_members.pluck(:job_id)
    job_ids << workflow.job_id if workflow
    job_ids << scope_id if scope_type == "job" && scope_id.present?
    Job.where(id: job_ids.compact.uniq).order(:id).to_a
  end

  def mark_terminal!(state)
    raise ArgumentError, "state must be terminal" unless state.to_s.in?(TERMINAL_STATES)

    transaction do
      # Retiring the unit settles its intent and rolls up to its Job, so its
      # ancestry is locked first, top down (NY40).
      Lineage.lock!(self)
      update!(
        state: state.to_s,
        finished_at: finished_at || Time.current,
        blocked_reason: nil,
        blocked_at: nil,
        blocked_until: nil,
        blocked_details: {},
        blocked_by_user: nil
      )
      work_unit_locks.active.find_each(&:release!)
      # Inside the transaction: a finished unit and its intent's outcome commit
      # together, so neither a crash nor a failing sync can leave a terminal
      # unit with an open intent.
      WorkIntents::TerminalUnitSync.call(self)
    end
  end

  def preempt!(reason:, by_work_unit: nil)
    sync_terminal = false

    transaction do
      # Ancestry first, top down (NY40): preempting settles the intent.
      Lineage.lock!(self)
      reload
      if cancelled?
        update!(
          preemption_reason: preemption_reason.presence || reason.to_s.truncate(PREEMPTION_REASON_MAX_LENGTH),
          preempted_by_work_unit: preempted_by_work_unit || by_work_unit
        )
        sync_terminal = true
      elsif active?
        update!(
          state: "cancelled",
          finished_at: finished_at || Time.current,
          blocked_reason: nil,
        blocked_at: nil,
          blocked_until: nil,
          blocked_details: {},
          blocked_by_user: nil,
          preemption_reason: reason.to_s.truncate(PREEMPTION_REASON_MAX_LENGTH),
          preempted_by_work_unit: by_work_unit
        )
        work_unit_locks.active.find_each(&:release!)
        sync_terminal = true
      end
      # Same transaction as the cancellation, as in mark_terminal!.
      WorkIntents::TerminalUnitSync.call(self) if sync_terminal
    end

    self
  end

  def request_pause!
    update!(pause_requested: true)
  end

  def clear_pause!
    update!(pause_requested: false)
  end

  # Surrenders the repository landing slot so other landings can proceed while
  # this unit waits on capacity that does not exist yet. `ensure_active_locks!`
  # re-acquires it when the unit next starts running; if another landing holds
  # it by then, this unit waits its turn, which is contention rather than
  # starvation.
  def release_landing_locks!
    work_unit_locks
      .active
      .where("lock_key LIKE ?", "#{LANDING_LOCK_KEY_PREFIX}%")
      .find_each(&:release!)
  end

  private

  # A landing blocked before its first Run gives the repository slot back,
  # whatever the reason (decision NY7, formal/SyrusModel/PrestartSlot.lean):
  # an allowlist of reasons starved every other landing in the repository
  # three times, most recently on a manual pause. Nothing is lost: the
  # Workflow's start (WorkflowLifecycle.started! -> mark_running!) and
  # resume_for_workflow! re-acquire every key before the first Run.
  def prestart_landing_block?
    workflow&.queued_landing_before_first_run? || false
  end

  def ensure_active_locks!
    retried = Set.new
    lock_keys_for_runtime.each do |lock_key|
      next if work_unit_locks.active.exists?(lock_key: lock_key)

      owner = WorkUnits::Ownership.active_unit_for_lock_key(lock_key)
      if owner
        if !same_runtime_lock_owner?(owner) &&
            definition.lock_conflicts_enforced? &&
            !WorkUnits::Ownership.nonblocking_main_branch_repair_repository_lock?(owner, lock_key)
          raise WorkUnits::Launcher::LockConflict.new(lock_key: lock_key, work_unit: owner)
        end
        next
      end

      work_unit_locks.create!(lock_key: lock_key)
    rescue ActiveRecord::RecordNotUnique
      owner = WorkUnits::Ownership.active_unit_for_lock_key(lock_key)
      if owner.nil?
        # The holder released the key between our insert and the lookup: the
        # key is free and we hold nothing. Try once more, then fail closed
        # rather than run without the lock (formal/SyrusModel/LockAcquire.lean).
        raise WorkUnits::Launcher::LockConflict.new(lock_key: lock_key, work_unit: nil) if retried.include?(lock_key)

        retried << lock_key
        retry
      end
      if !same_runtime_lock_owner?(owner) &&
          definition.lock_conflicts_enforced? &&
          !WorkUnits::Ownership.nonblocking_main_branch_repair_repository_lock?(owner, lock_key)
        raise WorkUnits::Launcher::LockConflict.new(lock_key: lock_key, work_unit: owner)
      end
    end
  end

  def same_runtime_lock_owner?(owner)
    return false unless owner
    return true if owner.id.to_i == id.to_i

    owner.workflow_id.present? && workflow_id.present? && owner.workflow_id.to_i == workflow_id.to_i
  end

  def lock_keys_for_runtime
    return [] unless workflow

    definition.lock_keys_for(
      job: primary_job || workflow.job,
      member_jobs: runtime_member_jobs,
      artifacts: workflow.artifacts.to_h
    )
  end

  def runtime_member_jobs
    jobs = work_unit_members.includes(:job).order(:id).map(&:job).compact
    jobs.presence || [ workflow.job ].compact
  end

  def reactivate_work_intent!
    return unless work_intent
    return if work_intent.requested? || work_intent.waiting?

    work_intent.request!
  end

  def primary_job
    work_unit_members.includes(:job).find { |member| member.role == "primary" }&.job
  end

  def normalize_blocked_details
    self.blocked_details ||= {}
  end

  # Backstops WorkUnits::Launcher#create_lock! at the DB level: only one
  # active WorkUnit may exist per (scope, kind) for kinds where
  # definition.lock_conflicts_enforced? is true, so a second Workflow for
  # the same follow-up work can't be materialized even if an app-level
  # check is skipped or races . Kinds that intentionally allow
  # cross-job serialization queues (e.g. epic-wide feedback) aren't scoped
  # by job here, so they're unaffected.
  def sync_active_dedup_key
    # scope_id can be nil (e.g. an epic-scoped kind like stack_rebase
    # running for a job with no epic) — stringifying that would collapse
    # otherwise-unrelated units onto the same "<scope_type>::<kind>" key,
    # so skip the dedup guarantee rather than false-collide them. The
    # per-job lock keys in create_lock! still protect these cases.
    self.active_dedup_key = active? && scope_id.present? && lock_conflicts_enforced_for_kind? ? "#{scope_type}:#{scope_id}:#{kind}" : nil
  end

  # A WorkUnit's kind can belong to a plugin that has since been
  # disabled (WorkDefinitions.for raises UnknownKind in that case, per
  # the plugin-registry contract — see docs/engineering/conventions/plugins/authoring.md).
  # This callback runs on every save, so it must degrade to "not
  # enforced" rather than raise, or transitioning/finalizing a WorkUnit
  # whose plugin went away mid-flight would start failing outright.
  def lock_conflicts_enforced_for_kind?
    definition.lock_conflicts_enforced?
  rescue WorkDefinitions::UnknownKind
    false
  end
end
