class JobClassificationAttempt < ApplicationRecord
  OUTCOMES = %w[classified uncertain errored].freeze
  RAW_OUTPUT_LIMIT = 64.kilobytes
  ERROR_LIMIT = 4.kilobytes

  belongs_to :job
  belongs_to :spawned_process, optional: true

  validates :started_at, presence: true
  validates :outcome, inclusion: { in: OUTCOMES }, allow_nil: true

  scope :latest_first, -> { order(started_at: :desc, id: :desc) }
  scope :in_flight, -> { where(finished_at: nil) }

  def in_flight?
    finished_at.nil?
  end

  def finish!(outcome:, decision: nil, error: nil, raw_output: nil, finished_at: Time.current)
    update!(
      outcome: outcome,
      decision: decision,
      error: error.to_s.truncate(ERROR_LIMIT).presence,
      raw_output: raw_output.to_s.truncate(RAW_OUTPUT_LIMIT).presence,
      finished_at: finished_at
    )
  end
end
