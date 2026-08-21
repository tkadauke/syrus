class JobLog < ApplicationRecord
  belongs_to :run

  MAX_APPEND_ATTEMPTS = 5
  NEXT_SEQUENCE_CACHE_KEY = :syrus_job_log_next_sequence_by_run_id

  # Sequence numbers used to be serialized behind a `SELECT ... FOR UPDATE`
  # on the parent Run row. High-output runs stream stdout/stderr from
  # multiple threads concurrently, so every chunk append contended for the
  # same Run row lock — and so did unrelated writes to that row (heartbeat
  # bumps, state transitions), turning a single busy run into a lock convoy
  # measured in seconds per query. The unique index on (run_id, sequence)
  # is sufficient to prevent duplicate sequences on its own: read the
  # current max optimistically, insert, and retry with a fresh max on the
  # rare collision instead of locking. `run.id` is used directly (never a
  # freshly-loaded Run instance) so a caller's in-memory run can carry
  # unsaved dirty state without it leaking into this write.
  def self.append!(run:, chunk:, kind: nil)
    text = utf8(chunk)
    return nil if text.strip.empty?

    attempts = 0
    begin
      log = create!(run_id: run.id, chunk: text, sequence: next_sequence_for(run.id), kind: kind)
      remember_next_sequence!(run.id, log.sequence + 1)
      log
    rescue ActiveRecord::RecordNotUnique
      forget_next_sequence!(run.id)
      attempts += 1
      retry if attempts < MAX_APPEND_ATTEMPTS
      raise
    rescue ActiveRecord::RecordInvalid => e
      raise unless e.record.errors.of_kind?(:sequence, :taken)
      forget_next_sequence!(run.id)
      attempts += 1
      retry if attempts < MAX_APPEND_ATTEMPTS
      raise
    end
  end

  def self.next_sequence_for(run_id)
    cached = next_sequence_cache[run_id.to_i]
    return cached if cached

    (where(run_id: run_id).maximum(:sequence) || -1) + 1
  end
  private_class_method :next_sequence_for

  def self.clear_sequence_cache!
    Thread.current[NEXT_SEQUENCE_CACHE_KEY] = {}
  end

  def self.remember_next_sequence!(run_id, sequence)
    next_sequence_cache[run_id.to_i] = sequence.to_i
  end
  private_class_method :remember_next_sequence!

  def self.forget_next_sequence!(run_id)
    next_sequence_cache.delete(run_id.to_i)
  end
  private_class_method :forget_next_sequence!

  def self.next_sequence_cache
    Thread.current[NEXT_SEQUENCE_CACHE_KEY] ||= {}
  end
  private_class_method :next_sequence_cache

  validates :chunk, presence: true
  validates :sequence, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :sequence, uniqueness: { scope: :run_id }

  before_update { raise ActiveRecord::ReadOnlyRecord, "JobLog is append-only" }
  before_destroy { raise ActiveRecord::ReadOnlyRecord, "JobLog is append-only" unless destroyed_by_association }

  def self.utf8(chunk)
    string = chunk.to_s
    if string.encoding == Encoding::ASCII_8BIT
      string.dup.force_encoding(Encoding::UTF_8).scrub("")
    else
      string.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "")
    end
  end
  private_class_method :utf8
end
