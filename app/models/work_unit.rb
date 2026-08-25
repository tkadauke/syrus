class WorkUnit < ApplicationRecord
  STATES = %w[queued blocked running succeeded failed cancelled].freeze
  BLOCKED_REASONS = %w[
    admission_control
    provider_availability
    manual_pause
    main_branch_health
    dependency_failed
    stack_dependencies_not_ready
    stack_fan_in_base_unavailable
    job_not_ready_for_execution
    urgent_job_active
    epic_wide_workflow_active
    resource_safety
    ci_repair_safety
    active_work_lock
    auto_retry_backoff
    preempted
  ].freeze

  belongs_to :work_intent
  belongs_to :repository, optional: true
  belongs_to :source_repository, class_name: "Repository", optional: true
  belongs_to :target_repository, class_name: "Repository", optional: true
  belongs_to :workflow, optional: true
  belongs_to :parent_work_unit, class_name: "WorkUnit", optional: true
  belongs_to :preempted_by_work_unit, class_name: "WorkUnit", optional: true
  belongs_to :blocked_by_user, class_name: "User", optional: true

  has_many :child_work_units, class_name: "WorkUnit", foreign_key: :parent_work_unit_id, dependent: nil, inverse_of: :parent_work_unit
  has_many :work_unit_members, dependent: nil
  has_many :member_jobs, through: :work_unit_members, source: :job
  has_many :work_unit_locks, dependent: nil

  before_validation :normalize_blocked_details

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

  def block!(reason:, blocked_until: nil, details: {}, user: nil)
    update!(
      state: "blocked",
      blocked_reason: reason,
      blocked_until: blocked_until,
      blocked_details: details || {},
      blocked_by_user: user
    )
  end

  def unblock!
    update!(
      state: "queued",
      blocked_reason: nil,
      blocked_until: nil,
      blocked_details: {},
      blocked_by_user: nil
    )
  end

  def mark_running!
    transaction do
      ensure_active_locks!
      update!(
        state: "running",
        started_at: started_at || Time.current,
        finished_at: nil,
        blocked_reason: nil,
        blocked_until: nil,
        blocked_details: {},
        blocked_by_user: nil
      )
    end
  end

  def mark_terminal!(state)
    raise ArgumentError, "state must be terminal" unless state.to_s.in?(%w[succeeded failed cancelled])

    transaction do
      update!(
        state: state.to_s,
        finished_at: finished_at || Time.current,
        blocked_reason: nil,
        blocked_until: nil,
        blocked_details: {},
        blocked_by_user: nil
      )
      work_unit_locks.active.find_each(&:release!)
    end

    WorkIntents::TerminalUnitSync.call(self)
  end

  def preempt!(reason:, by_work_unit: nil)
    transaction do
      update!(
        state: "cancelled",
        finished_at: finished_at || Time.current,
        blocked_reason: nil,
        blocked_until: nil,
        blocked_details: {},
        blocked_by_user: nil,
        preemption_reason: reason,
        preempted_by_work_unit: by_work_unit
      )
      work_unit_locks.active.find_each(&:release!)
    end

    WorkIntents::TerminalUnitSync.call(self)
  end

  def request_pause!
    update!(pause_requested: true)
  end

  def clear_pause!
    update!(pause_requested: false)
  end

  private

  def ensure_active_locks!
    lock_keys_for_runtime.each do |lock_key|
      next if work_unit_locks.active.exists?(lock_key: lock_key)

      owner = WorkUnits::Ownership.active_unit_for_lock_key(lock_key)
      if owner && !same_runtime_lock_owner?(owner) && definition.lock_conflicts_enforced?
        raise WorkUnits::Launcher::LockConflict.new(lock_key: lock_key, work_unit: owner)
      end
      next if owner

      work_unit_locks.create!(lock_key: lock_key)
    rescue ActiveRecord::RecordNotUnique
      owner = WorkUnits::Ownership.active_unit_for_lock_key(lock_key)
      if owner && !same_runtime_lock_owner?(owner) && definition.lock_conflicts_enforced?
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

  def primary_job
    work_unit_members.includes(:job).find { |member| member.role == "primary" }&.job
  end

  def normalize_blocked_details
    self.blocked_details ||= {}
  end
end
