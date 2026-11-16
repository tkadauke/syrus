class CommandSpan < ApplicationRecord
  MAX_ALLOCATION_ATTEMPTS = 5
  OUTCOMES = %w[ succeeded failed timed_out stopped operator_killed incomplete ].freeze

  belongs_to :job
  belongs_to :workflow
  belongs_to :step
  belongs_to :run
  belongs_to :spawned_process, optional: true

  validates :sequence, numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validates :name, :command_excerpt, :started_at, presence: true
  validates :outcome, inclusion: { in: OUTCOMES, allow_nil: true }
  validates :sequence, uniqueness: { scope: :run_id }
  validates :idempotency_key, uniqueness: { scope: :run_id }, allow_nil: true
  before_validation :default_metadata

  scope :ordered, -> { order(:sequence, :id) }

  # Command spans are written by grader and prepare processes which may run on
  # different workers for the same Run. Serialize the shared sequence namespace
  # on the parent row, and resolve the semantic event before allocating so a
  # retry after a committed insert adopts the original row.
  def self.record!(run:, idempotency_key:, **attributes)
    attempts = 0

    begin
      transaction(requires_new: true) do
        Run.where(id: run.id).lock(true).pick(:id) || raise(ActiveRecord::RecordNotFound)

        existing = lock.find_by(run_id: run.id, idempotency_key: idempotency_key)
        return existing if existing

        create!(
          **attributes,
          run: run,
          idempotency_key: idempotency_key,
          sequence: (where(run_id: run.id).maximum(:sequence) || 0) + 1
        )
      end
    rescue ActiveRecord::RecordNotUnique
      existing = lock.find_by(run_id: run.id, idempotency_key: idempotency_key)
      return existing if existing

      attempts += 1
      retry if attempts < MAX_ALLOCATION_ATTEMPTS
      raise
    rescue ActiveRecord::RecordInvalid => error
      raise unless error.record.errors.of_kind?(:sequence, :taken) ||
        error.record.errors.of_kind?(:idempotency_key, :taken)

      attempts += 1
      retry if attempts < MAX_ALLOCATION_ATTEMPTS
      raise
    rescue ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout
      attempts += 1
      retry if attempts < MAX_ALLOCATION_ATTEMPTS
      raise
    end
  end

  def duration_s
    return unless duration_ms

    (duration_ms.to_f / 1000).round(3)
  end

  private

  def default_metadata
    self.metadata ||= {}
    self.resource_attribution ||= {}
  end
end
