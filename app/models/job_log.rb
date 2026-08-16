class JobLog < ApplicationRecord
  belongs_to :run

  MAX_APPEND_ATTEMPTS = 5

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
      create!(run_id: run.id, chunk: text, sequence: next_sequence_for(run.id), kind: kind)
    rescue ActiveRecord::RecordNotUnique
      attempts += 1
      retry if attempts < MAX_APPEND_ATTEMPTS
      raise
    rescue ActiveRecord::RecordInvalid => e
      raise unless e.record.errors.of_kind?(:sequence, :taken)
      attempts += 1
      retry if attempts < MAX_APPEND_ATTEMPTS
      raise
    end
  end

  def self.next_sequence_for(run_id)
    (where(run_id: run_id).maximum(:sequence) || -1) + 1
  end
  private_class_method :next_sequence_for

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
