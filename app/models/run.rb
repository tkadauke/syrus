class Run < ApplicationRecord
  include AASM

  TRIGGER_KINDS = %w[ initial pr_comment ci_failure replay manual ].freeze

  belongs_to :job
  has_many :job_logs, -> { order(:sequence) }, dependent: :destroy

  validates :trigger_kind, presence: true, inclusion: { in: TRIGGER_KINDS }

  scope :active, -> { where(state: %w[ queued running ]) }
  scope :terminal, -> { where(state: %w[ succeeded failed cancelled ]) }
  scope :ordered, -> { order(:created_at) }

  aasm column: :state, whiny_transitions: false do
    state :queued, initial: true
    state :running, :succeeded, :failed, :cancelled

    event :start do
      transitions from: :queued, to: :running, after: -> { self.started_at = Time.current }
    end

    event :succeed do
      transitions from: :running, to: :succeeded, after: -> { self.finished_at = Time.current }
    end

    event :fail do
      transitions from: [ :queued, :running ], to: :failed, after: -> { self.finished_at = Time.current }
    end

    event :cancel do
      transitions from: [ :queued, :running ], to: :cancelled, after: -> { self.finished_at = Time.current }
    end
  end

  after_create_commit :enqueue_run_job

  # State changes (queued → running → succeeded/failed/cancelled) and
  # field updates (agent_turns, agent_outcome, agent_diff) all need to
  # show up on the Job's show page without requiring the operator to
  # refresh. Broadcasting refreshes to the parent Job's stream means
  # "tell anyone watching this Job to morph itself".
  broadcasts_refreshes_to ->(run) { run.job }

  def self.average_duration_for(trigger_kind)
    completed = terminal.where(trigger_kind: trigger_kind)
                        .where.not(started_at: nil, finished_at: nil)
    return nil if completed.empty?
    total = completed.sum { |r| r.finished_at - r.started_at }
    (total / completed.size).to_i
  end

  def initial?
    trigger_kind == "initial"
  end

  def terminal?
    succeeded? || failed? || cancelled?
  end

  private

  def enqueue_run_job
    return if terminal?
    RunJob.perform_later(id)
  end
end
