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

    @mutex = Mutex.new
    @buffer = Hash.new(0)

    class << self
      # Off in tests, which flush explicitly.
      attr_writer :auto_flush

      def auto_flush = @auto_flush.nil? ? !Rails.env.test? : @auto_flush

      def record(name, labels, by)
        @mutex.synchronize { @buffer[[ name.to_s, canonical(labels) ]] += by }
        ensure_flusher
      end

      # Writes everything buffered. Returns the number of series written.
      def flush!
        pending = @mutex.synchronize do
          taken = @buffer
          @buffer = Hash.new(0)
          taken
        end
        return 0 if pending.empty?

        write(pending)
        pending.size
      rescue StandardError => e
        @mutex.synchronize { pending.each { |key, by| @buffer[key] += by } }
        Rails.logger.warn("[Metrics::ClusterCounters] flush failed, keeping #{pending.size} series for the next one: #{e.class}: #{e.message}")
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

      def reset!
        @mutex.synchronize { @buffer = Hash.new(0) }
      end

      private

      def canonical(labels)
        labels.to_h.transform_keys(&:to_s).transform_values { |value| value&.to_s }.sort.to_h
      end

      def write(pending)
        now = Time.current
        rows = pending.map do |(name, labels), by|
          { name: name, labels_digest: Digest::SHA256.hexdigest(labels.to_json), labels: labels,
            value: by, created_at: now, updated_at: now }
        end
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          MetricCounterTotal.upsert_all(rows, **upsert_options(connection))
        end
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
