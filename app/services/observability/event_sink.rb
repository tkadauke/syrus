require "fileutils"
require "securerandom"

module Observability
  module EventSink
    MEMORY_LIMIT = Integer(ENV["SYRUS_OBSERVABILITY_MEMORY_EVENTS"], exception: false) || 500
    PERFORMANCE_MEMORY_LIMIT = Integer(ENV["SYRUS_PERFORMANCE_MEMORY_EVENTS"], exception: false) || 2_000
    FLUSH_BATCH_SIZE = Integer(ENV["SYRUS_OBSERVABILITY_FLUSH_BATCH_SIZE"], exception: false) || 250

    # How long a buffer may sit unflushed. Every process runs its own flusher,
    # so this is the floor on statement count: with N processes it costs N
    # INSERTs per interval per kind even when almost nothing happened. It was
    # 15s, which on production meant ~9-row batches -- the batching existed but
    # never filled. Paired with FLUSH_THRESHOLD below, a busy kind now flushes
    # on size and a quiet one costs one statement a minute.
    FLUSH_INTERVAL = (Integer(ENV["SYRUS_OBSERVABILITY_FLUSH_INTERVAL_SECONDS"], exception: false) || 60).seconds

    # Flush as soon as a buffer reaches this, without waiting for the interval.
    # This is what keeps a burst from being written a handful of rows at a time,
    # and it is well under PERFORMANCE_MEMORY_LIMIT so a busy process still
    # writes long before it would start dropping.
    FLUSH_THRESHOLD = Integer(ENV["SYRUS_OBSERVABILITY_FLUSH_THRESHOLD"], exception: false) || 200

    # How often the flusher wakes to *check*. Decoupled from FLUSH_INTERVAL so
    # a size-triggered flush is prompt without every kind being written every
    # tick.
    FLUSH_TICK = (Integer(ENV["SYRUS_OBSERVABILITY_FLUSH_TICK_SECONDS"], exception: false) || 5).seconds

    # Ceiling on events accepted per kind per minute, per process.
    #
    # Observability thresholds here are absolute, so a degraded instance crosses
    # them constantly: the slower the database gets, the more slow_sql and
    # slow_phase rows are written, which makes it slower. That feedback loop is
    # the thing this cap exists to break. Past the ceiling events are counted in
    # `stats[:dropped]` rather than written, so the signal degrades to a sample
    # instead of amplifying the incident it is describing.
    RATE_LIMIT_PER_MINUTE = Integer(ENV["SYRUS_OBSERVABILITY_RATE_LIMIT_PER_MINUTE"], exception: false) || 600

    @mutex = Mutex.new
    @flush_mutex = Mutex.new
    @buffers = Hash.new { |hash, key| hash[key] = [] }
    @dropped = Hash.new(0)
    @flusher_thread = nil
    @buffer_started_at = {}
    @rate_window_started_at = {}
    @rate_window_count = Hash.new(0)

    module_function

    def append(kind:, event:, durable: false)
      kind = normalize_kind(kind)
      # Durable kinds are exempt: they are spooled to disk precisely because
      # losing one is not acceptable, so sampling them would defeat the point.
      durable_kind = durable || Observability::EventStream.fetch(kind).durable?
      return nil if !durable_kind && rate_limited?(kind)

      event = normalized_event(event)
      append_memory(kind, event)
      append_spool(kind, event) if durable_kind
      start_background_flusher
      event
    rescue StandardError => e
      Rails.logger.error("[Observability::EventSink] append failed for #{kind} event, event dropped: #{e.class}: #{e.message}")
      nil
    end

    def recent(kind:, limit:)
      kind = normalize_kind(kind)
      limit = clamp_limit(limit, kind: kind)
      persisted = persisted_recent(kind, limit: limit)
      buffered = buffered_events(kind)
      (persisted + buffered)
        .uniq { |event| event_identity(event) }
        .sort_by { |event| event["occurred_at"].to_s }
        .last(limit)
        .reverse
    rescue StandardError
      buffered_events(kind).last(limit).reverse
    end

    def flush!(kinds: Observability::EventStream.kinds)
      Array(kinds).each { |kind| flush_kind!(normalize_kind(kind)) }
    end

    # Flushes only the kinds that have earned a write: a full-enough buffer, or
    # one that has waited out FLUSH_INTERVAL. Called on every tick, so a burst
    # is written promptly while a quiet kind costs one statement per interval
    # rather than one per tick.
    def flush_due!(now: Time.current)
      Observability::EventStream.kinds.each do |kind|
        kind = normalize_kind(kind)
        next unless flush_due?(kind, now: now)

        flush_kind!(kind)
      end
    end

    def flush_due?(kind, now: Time.current)
      @mutex.synchronize do
        buffered = @buffers[kind].size
        next false if buffered.zero?
        next true if buffered >= FLUSH_THRESHOLD

        # Age of the OLDEST event in the buffer, not time since some previous
        # flush: the interval is a bound on how long an event may wait, and a
        # kind that has never flushed should not read as instantly overdue.
        started = @buffer_started_at[kind]
        started.present? && (now - started) >= FLUSH_INTERVAL
      end
    end

    def clear!(kind: nil)
      @mutex.synchronize do
        if kind
          kind = normalize_kind(kind)
          @buffers[kind] = []
          reset_pacing(kind)
          clear_spool(kind)
        else
          @buffers.clear
          @dropped.clear
          @buffer_started_at.clear
          @rate_window_started_at.clear
          @rate_window_count.clear
          Observability::EventStream.kinds.each { |event_kind| clear_spool(event_kind) }
        end
      end
    end

    def stats
      @mutex.synchronize do
        {
          buffered: @buffers.transform_values(&:size),
          dropped: @dropped.dup,
          spool_root: spool_root.to_s,
          background_flusher: @flusher_thread&.alive? || false
        }
      end
    end

    def clamp_limit(limit, kind: nil)
      [[limit.to_i, 1].max, memory_limit(kind)].min
    end

    def flush_kind!(kind)
      events = []
      @flush_mutex.synchronize do
        events = drain_memory(kind)
        events.concat(drain_spool(kind))
        events = events.uniq { |event| event_identity(event) }
        return if events.empty?

        Observability::EventStream.fetch(kind).persist!(events, batch_size: FLUSH_BATCH_SIZE)
      end
    rescue StandardError => e
      Rails.logger.error("[Observability::EventSink] flush failed for #{kind}, #{events.size} event(s) restored to buffer: #{e.class}: #{e.message}")
      restore_memory(kind, events)
      nil
    end

    def start_background_flusher
      return unless background_flusher_enabled?
      return if @mutex.synchronize { @flusher_thread&.alive? }

      @mutex.synchronize do
        return if @flusher_thread&.alive?

        @flusher_thread = Thread.new do
          Thread.current.name = "syrus-observability-flusher" if Thread.current.respond_to?(:name=)
          Thread.current.report_on_exception = false
          loop do
            sleep FLUSH_TICK
            flush_due!
          rescue StandardError => e
            Rails.logger.error("[Observability::EventSink] background flusher iteration failed: #{e.class}: #{e.message}")
          end
        end
      end
    end

    def background_flusher_enabled?
      configured = ENV["SYRUS_OBSERVABILITY_BACKGROUND_FLUSHER"]
      return ActiveModel::Type::Boolean.new.cast(configured) unless configured.nil?

      !Rails.env.test?
    end

    def persisted_recent(kind, limit:)
      Observability::EventStream.fetch(kind).recent(limit: limit)
    end

    # Fixed-window counter rather than a token bucket: one comparison and one
    # increment under the lock, on a path that runs for every event the app
    # emits. A burst can cross into a new window early, which is a fine trade
    # for a sampler whose job is to bound the worst case, not to smooth it.
    def rate_limited?(kind)
      return false if RATE_LIMIT_PER_MINUTE <= 0

      @mutex.synchronize do
        now = Time.current
        started = @rate_window_started_at[kind]
        if started.nil? || (now - started) >= 60
          @rate_window_started_at[kind] = now
          @rate_window_count[kind] = 0
        end

        if @rate_window_count[kind] >= RATE_LIMIT_PER_MINUTE
          @dropped[kind] += 1
          true
        else
          @rate_window_count[kind] += 1
          false
        end
      end
    end

    # `clear!` means "this sink is as it was at boot", so the pacing counters go
    # with the buffer. Leaving them behind would make a cleared sink refuse to
    # accept events it has no record of having seen.
    def reset_pacing(kind)
      @dropped.delete(kind)
      @buffer_started_at.delete(kind)
      @rate_window_started_at.delete(kind)
      @rate_window_count.delete(kind)
    end

    def append_memory(kind, event)
      @mutex.synchronize do
        buffer = @buffers[kind]
        # The clock starts when a buffer goes from empty to holding something.
        @buffer_started_at[kind] ||= Time.current
        buffer << event
        overflow = buffer.size - memory_limit(kind)
        if overflow.positive?
          @dropped[kind] += overflow
          @buffers[kind] = buffer.last(memory_limit(kind))
        end
      end
    end

    def restore_memory(kind, events)
      return if events.blank?

      @mutex.synchronize do
        @buffers[kind] = (events + @buffers[kind]).last(memory_limit(kind))
        @buffer_started_at[kind] ||= Time.current
      end
    end

    def drain_memory(kind)
      @mutex.synchronize do
        events = @buffers[kind]
        @buffers[kind] = []
        @buffer_started_at.delete(kind)
        events
      end
    end

    def buffered_events(kind)
      @mutex.synchronize { @buffers[kind].dup }
    end

    def append_spool(kind, event)
      FileUtils.mkdir_p(spool_dir(kind))
      File.open(spool_path(kind), "a") { |file| file.puts(JSON.generate(event)) }
    rescue StandardError
      nil
    end

    def clear_spool(kind)
      FileUtils.rm_rf(spool_dir(kind))
    rescue StandardError
      nil
    end

    def drain_spool(kind)
      dir = spool_dir(kind)
      return [] unless dir.exist?

      Dir.children(dir).grep(/\.jsonl\z/).flat_map do |filename|
        path = dir.join(filename)
        claimed = dir.join("#{filename}.#{Process.pid}.claiming")
        File.rename(path, claimed)
        events = File.readlines(claimed, chomp: true).filter_map { |line| JSON.parse(line) rescue nil }
        File.delete(claimed)
        events
      rescue StandardError
        []
      end
    end

    def spool_path(kind)
      spool_dir(kind).join("#{process_identity}.jsonl")
    end

    def spool_dir(kind)
      spool_root.join(kind.to_s, SyrusVersion.hostname.to_s.presence || "unknown-host")
    end

    def spool_root
      Pathname.new(ENV.fetch("SYRUS_OBSERVABILITY_SPOOL_ROOT") {
        Rails.root.join("tmp", "observability_spool#{test_worker_suffix}").to_s
      })
    end

    # parallel_tests gives each worker its own database (config/database.yml's
    # storage/test<TEST_ENV_NUMBER>.sqlite3), so job/workflow/run ids collide
    # across concurrently-running workers. The durable spool is a shared
    # filesystem path keyed only by kind+hostname; without a matching
    # per-worker suffix, one worker's buffered "durable" events (e.g.
    # WorkflowActivity's landing_queue_changed) get drained and persisted by
    # a *different* worker's flush, leaking rows whose ids coincidentally
    # match that worker's own records.
    def test_worker_suffix
      return "" unless Rails.env.test?

      "-#{ENV["TEST_ENV_NUMBER"].presence || "1"}"
    end

    def process_identity
      @process_identity ||= [
        ENV["SYRUS_PROCESS_ROLE"].presence || ENV["RAILS_PROCESS_ROLE"].presence || "rails",
        Process.pid,
        SecureRandom.hex(6)
      ].join("-")
    end

    def normalize_kind(kind)
      Observability::EventStream.fetch(kind).kind
    end

    def memory_limit(kind)
      return MEMORY_LIMIT if kind.nil?

      normalize_kind(kind) == :performance ? PERFORMANCE_MEMORY_LIMIT : MEMORY_LIMIT
    end

    def normalized_event(event)
      event.to_h.deep_stringify_keys
    end

    def event_identity(event)
      [ event["occurred_at"], event["event"], event["request_id"], event["phase"], event["name"], event["message"] ]
    end
  end
end
