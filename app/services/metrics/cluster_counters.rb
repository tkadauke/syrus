module Metrics
  # Makes `cluster: true` counters count across processes.
  #
  # Web runs one process, but a worker pod runs a Solid Queue supervisor that
  # forks a process per queue, and they share no memory. A counter bumped in
  # the `runs` process was invisible to /metrics, which only web serves. So
  # each process buffers its increments here and flushes them every
  # FLUSH_INTERVAL as one atomic `value = value + delta` upsert per series
  # into metric_counter_totals; ClusterCounterSampler snapshots that table on
  # the metrics tick, and web's /metrics renders the cluster-wide totals.
  #
  # The contract every instrumentation call relies on still holds: recording
  # never raises and never blocks -- it adds to an in-memory buffer; the
  # database write happens on a background thread. A failed flush keeps its
  # deltas for the next one. What a process has not flushed when it is killed
  # (SIGKILL, OOM) is lost, which the rates tolerate; an orderly exit flushes.
  #
  # These are cluster totals, so every web replica renders the same numbers:
  # aggregate with `max by`, never `sum`, like the other GLOBAL series.
  module ClusterCounters
    FLUSH_INTERVAL = 10.seconds
    STALE_AFTER = 3 * FLUSH_INTERVAL
    FORGET_AFTER = 5.minutes
    Batch = Data.define(:identity, :sequence, :deltas)

    @mutex = Mutex.new
    @flush_mutex = Mutex.new
    @buffer = Hash.new(0)
    @pending_batches = []

    class << self
      # Off in tests, which flush explicitly.
      attr_writer :auto_flush

      def auto_flush = @auto_flush.nil? ? !Rails.env.test? : @auto_flush

      def record(name, labels, by)
        process_identity
        @mutex.synchronize { @buffer[[ name.to_s, canonical(labels) ]] += by }
        ensure_flusher
      end

      # Writes everything buffered. Returns the number of series written.
      def flush!
        @flush_mutex.synchronize do
          enqueue_buffer
          return heartbeat! if @pending_batches.empty?

          written = 0
          while (batch = @pending_batches.first)
            written += batch.deltas.size if write(batch)
            @mutex.synchronize { @pending_batches.shift }
          end
          written
        end
      rescue StandardError => e
        mark_error(e)
        Rails.logger.warn("[Metrics::ClusterCounters] flush failed, keeping the immutable batch for the next attempt: #{e.class}: #{e.message}")
        0
      end

      # { name => [[labels, total], ...] } for every series in the table.
      # A plain Hash: the sampler caches it, and a default proc cannot be
      # serialized.
      def totals
        MetricCounterTotal.pluck(:name, :labels, :value).each_with_object({}) do |(name, labels, value), out|
          (out[name] ||= []) << [ labels.to_h.symbolize_keys, value.to_f ]
        end
      end

      def capture_status(now: Time.current)
        contributors = MetricCounterContributor.where(updated_at: (now - FORGET_AFTER)..).to_a
        return "available" if contributors.empty?

        partial = contributors.any? do |contributor|
          failed = contributor.last_error_at.present? &&
            (contributor.last_success_at.nil? || contributor.last_error_at > contributor.last_success_at)
          failed || contributor.updated_at < now - STALE_AFTER
        end
        partial ? "partial" : "available"
      end

      def reset!
        @mutex.synchronize do
          @buffer = Hash.new(0)
          @pending_batches = []
          @identity = nil
          @identity_pid = nil
          @sequence = 0
        end
      end

      private

      def canonical(labels)
        labels.to_h.transform_keys(&:to_s).transform_values { |value| value&.to_s }.sort.to_h
      end

      def process_identity
        return @identity if @identity_pid == Process.pid && @identity

        @mutex.synchronize do
          if @identity_pid != Process.pid || @identity.nil?
            @identity_pid = Process.pid
            @identity = "#{Socket.gethostname}:#{Process.pid}:#{SecureRandom.uuid}"
            @sequence = 0
            @pending_batches = []
            @buffer = Hash.new(0)
          end
          @identity
        end
      end

      def enqueue_buffer
        identity = process_identity
        @mutex.synchronize do
          return if @buffer.empty?

          @sequence += 1
          @pending_batches << Batch.new(identity:, sequence: @sequence, deltas: @buffer)
          @buffer = Hash.new(0)
        end
      end

      def write(batch)
        now = Time.current
        rows = batch.deltas.map do |(name, labels), by|
          { name: name, labels_digest: Digest::SHA256.hexdigest(labels.to_json), labels: labels,
            value: by, created_at: now, updated_at: now }
        end
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          ensure_contributor(batch.identity)
          MetricCounterContributor.transaction do
            contributor = locked_contributor(batch.identity)
            if batch.sequence <= contributor.last_applied_sequence
              contributor.update!(last_success_at: now, last_error_at: nil, last_error: nil)
              next false
            end

            MetricCounterTotal.upsert_all(rows, **upsert_options(connection))
            contributor.update!(last_applied_sequence: batch.sequence, last_success_at: now,
                                last_error_at: nil, last_error: nil)
            true
          end
        end
      end

      def ensure_contributor(identity)
        MetricCounterContributor.find_or_create_by!(identity: identity)
      rescue ActiveRecord::RecordNotUnique
        retry
      end

      def locked_contributor(identity)
        MetricCounterContributor.lock.find_by!(identity: identity)
      end

      def heartbeat!
        identity = @identity
        return 0 unless identity

        now = Time.current
        MetricCounterContributor.where(identity: identity).update_all(
          last_success_at: now, last_error_at: nil, last_error: nil, updated_at: now
        )
        0
      end

      def mark_error(error)
        identity = @identity
        return unless identity

        now = Time.current
        MetricCounterContributor.where(identity: identity).update_all(
          last_error_at: now, last_error: "#{error.class}: #{error.message}".truncate(500), updated_at: now
        )
      rescue StandardError
        nil
      end

      # The increment is done by the database, so concurrent flushes from
      # many processes add up rather than overwrite each other.
      def upsert_options(connection)
        if connection.adapter_name.match?(/mysql|trilogy/i)
          { on_duplicate: Arel.sql("value = value + VALUES(value), updated_at = VALUES(updated_at)") }
        else
          { unique_by: %i[name labels_digest],
            on_duplicate: Arel.sql("value = metric_counter_totals.value + excluded.value, updated_at = excluded.updated_at") }
        end
      end

      # One flusher thread per process, started lazily so a forked child
      # (whose parent's thread did not survive the fork) starts its own.
      def ensure_flusher
        return unless auto_flush
        return if @flusher_pid == Process.pid && @flusher&.alive?

        @mutex.synchronize do
          return if @flusher_pid == Process.pid && @flusher&.alive?

          @flusher_pid = Process.pid
          @flusher = Thread.new do
            Thread.current.name = "metrics-cluster-counters"
            loop do
              sleep FLUSH_INTERVAL
              Rails.application.executor.wrap { flush! }
            end
          end
          at_exit { flush! }
        end
      end
    end
  end
end
