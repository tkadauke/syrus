class JobLog < ApplicationRecord
  include HasConfigurableRetention

  belongs_to :run

  configurable_retention setting_key: :job_log_retention_days, unit: :days

  scope :prunable, -> {
    cutoff = retention_cutoff
    cutoff ? where("created_at < ?", cutoff) : none
  }

  MAX_APPEND_ATTEMPTS = 5
  MAX_TOOL_RESULT_BYTES = 1.megabyte
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
  def self.append!(run:, chunk:, kind: nil, tool_name: nil, tool_input: nil,
                   tool_use_id: nil, tool_result_content: nil, tool_result_error: nil, **)
    text = utf8(chunk)
    return nil if text.strip.empty?

    tool_metadata = build_tool_metadata(
      tool_name: tool_name,
      tool_input: tool_input,
      tool_use_id: tool_use_id,
      tool_result_content: tool_result_content,
      tool_result_error: tool_result_error
    )
    attempts = 0
    sequence = next_sequence_for(run.id)
    begin
      log = create!(run_id: run.id, chunk: text, sequence: sequence, kind: kind,
                    tool_metadata: tool_metadata)
      remember_next_sequence!(run.id, log.sequence + 1)
      log
    rescue ActiveRecord::RecordNotUnique
      sequence = advance_sequence(run.id, sequence)
      attempts += 1
      retry if attempts < MAX_APPEND_ATTEMPTS
      append_with_run_lock!(run_id: run.id, chunk: text, kind: kind, tool_metadata: tool_metadata,
                            after: sequence - 1)
    rescue ActiveRecord::RecordInvalid => e
      raise unless e.record.errors.of_kind?(:sequence, :taken)
      sequence = advance_sequence(run.id, sequence)
      attempts += 1
      retry if attempts < MAX_APPEND_ATTEMPTS
      append_with_run_lock!(run_id: run.id, chunk: text, kind: kind, tool_metadata: tool_metadata,
                            after: sequence - 1)
    end
  end

  # A collision means another writer holds this slot. Re-reading MAX(sequence)
  # is not enough to find the next free one: when append! runs inside a
  # caller's open transaction -- as the landing queue's audit writes do, under
  # `Job.transaction` with the Job row locked -- the re-read answers from the
  # same snapshot it already answered from, so every retry recomputes the
  # identical colliding sequence and the append fails deterministically. That
  # is how a log line aborted whole landing transactions. Step past the
  # collision instead, and prefer the re-read only where it is already ahead.
  def self.advance_sequence(run_id, collided_at)
    forget_next_sequence!(run_id)
    [ next_sequence_for(run_id), collided_at + 1 ].max
  end
  private_class_method :advance_sequence

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

  # `after:` is the last sequence the lock-free path saw taken, so this path
  # starts beyond it rather than re-deriving a number already known to collide.
  #
  # The retry is deliberately outside the transaction. `retry` inside the block
  # re-ran the body without rolling anything back, leaving the same transaction
  # and the same read snapshot in place -- so the "fresh max" this fallback
  # exists to take was never fresh, and all five attempts failed identically.
  def self.append_with_run_lock!(run_id:, chunk:, kind:, tool_metadata:, after: nil)
    attempts = 0
    sequence = nil

    begin
      Run.transaction do
        Run.where(id: run_id).lock(true).pick(:id)
        sequence ||= [ (where(run_id: run_id).maximum(:sequence) || -1) + 1, after.to_i + 1 ].max
        log = create!(
          run_id: run_id,
          chunk: chunk,
          sequence: sequence,
          kind: kind,
          tool_metadata: tool_metadata
        )
        remember_next_sequence!(run_id, log.sequence + 1)
        log
      end
    rescue ActiveRecord::RecordNotUnique
      sequence = advance_sequence(run_id, sequence)
      attempts += 1
      retry if attempts < MAX_APPEND_ATTEMPTS
      raise
    rescue ActiveRecord::RecordInvalid => e
      raise unless e.record.errors.of_kind?(:sequence, :taken)

      sequence = advance_sequence(run_id, sequence)
      attempts += 1
      retry if attempts < MAX_APPEND_ATTEMPTS
      raise
    end
  end
  private_class_method :append_with_run_lock!

  def self.build_tool_metadata(tool_name:, tool_input:, tool_use_id:, tool_result_content:, tool_result_error:)
    metadata = {
      "tool_name" => tool_name,
      "tool_input" => tool_input,
      "tool_use_id" => tool_use_id,
      "tool_result_content" => bounded_tool_result(tool_result_content),
      "tool_result_error" => tool_result_error
    }.compact
    metadata.presence
  end
  private_class_method :build_tool_metadata

  def self.bounded_tool_result(content)
    return if content.nil?

    encoded = JSON.generate(content)
    return content if encoded.bytesize <= MAX_TOOL_RESULT_BYTES

    preview = encoded.byteslice(0, MAX_TOOL_RESULT_BYTES).to_s.force_encoding(Encoding::UTF_8).scrub("")
    {
      "truncated" => true,
      "original_bytes" => encoded.bytesize,
      "preview" => preview
    }
  rescue JSON::GeneratorError
    bounded_tool_result(utf8(content))
  end
  private_class_method :bounded_tool_result

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
