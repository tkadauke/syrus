class Epic < ApplicationRecord
  include AASM

  STATES = %w[ backlog ready in_progress done ].freeze
  MERGED_JOB_CLOSURE_REASONS = %w[ pr_merged external_pr_merged ].freeze

  attr_readonly :number

  belongs_to :user
  belongs_to :repository
  has_many :jobs, dependent: :nullify
  has_many :dependencies,
           class_name: "EpicDependency",
           dependent: :destroy,
           inverse_of: :epic
  has_many :depends_on_epics, through: :dependencies, source: :depends_on_epic
  has_many :dependent_links,
           class_name: "EpicDependency",
           foreign_key: :depends_on_epic_id,
           dependent: :destroy,
           inverse_of: :depends_on_epic
  has_many :dependent_epics, through: :dependent_links, source: :epic

  validates :number, presence: true, numericality: { only_integer: true, greater_than: 0 }, uniqueness: true
  validates :title, presence: true
  validates :state, presence: true, inclusion: { in: STATES }
  validate :repository_belongs_to_user

  before_validation :assign_number, on: :create

  broadcasts_refreshes_to ->(epic) { [ epic.user, "jobs" ] }
  broadcasts_refreshes_to ->(epic) { [ epic.repository, "jobs" ] }

  aasm column: :state, whiny_transitions: false do
    state :backlog, initial: true
    state :ready, :in_progress, :done

    event :auto_ready do
      transitions from: :backlog, to: :ready, guard: :ready_to_start?
    end

    event :start do
      transitions from: :ready, to: :in_progress, after: :unblock_child_jobs!
    end

    event :auto_complete do
      transitions from: :in_progress, to: :done, guard: :complete?, after: :stamp_done_at
    end
  end

  def display_number
    "EPIC-#{number}"
  end

  def releases_jobs_for_execution?
    @releasing_jobs_for_execution || in_progress? || done?
  end

  def ready_to_start?
    dependencies_done? && child_jobs_confirmed?
  end

  def complete?
    child_jobs = jobs.reload
    child_jobs.any? && child_jobs.all? { |job| job.closed? && MERGED_JOB_CLOSURE_REASONS.include?(job.closure_reason) }
  end

  def refresh_auto_state!
    if backlog? && may_auto_ready?
      auto_ready!
    elsif in_progress? && may_auto_complete?
      auto_complete!
    else
      false
    end
  end

  # Operator escape hatch for the card menu. This intentionally bypasses
  # the AASM graph while preserving side effects that matter to execution.
  def override_state!(target_state)
    target_state = target_state.to_s
    raise ArgumentError, "unknown Epic state: #{target_state}" unless STATES.include?(target_state)

    transaction do
      update!(state: target_state, done_at: target_state == "done" ? Time.current : nil)
      unblock_child_jobs! if target_state == "in_progress"
    end
  end

  def unblock_child_jobs!
    @releasing_jobs_for_execution = true
    begin
      jobs.find_each do |job|
        job.epic = self
        job.start_pending_workflows_if_dependencies_satisfied!
      end
    ensure
      @releasing_jobs_for_execution = false
    end
  end

  private

  def assign_number
    self.number ||= (self.class.maximum(:number) || 0) + 1
  end

  def repository_belongs_to_user
    return unless repository && user
    return if repository.user_id == user_id

    errors.add(:repository, "must belong to the same user")
  end

  def dependencies_done?
    depends_on_epics.all?(&:done?)
  end

  def child_jobs_confirmed?
    jobs.where(state: "triaging").none?
  end

  def stamp_done_at
    self.done_at = Time.current
  end
end
