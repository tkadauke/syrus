require "securerandom"

module PerformanceLogging
  class MemoryHighWaterSampler
    SAMPLE_INTERVAL = (Float(ENV.fetch("SYRUS_MEMORY_HIGH_WATER_INTERVAL_SECONDS", 1.0)) rescue 1.0)
    BUCKET_BYTES = 256.megabytes
    LIMIT_PERCENTAGES = [ 0.7, 0.8, 0.9 ].freeze
    STARTED_JOB_LIMIT = 50

    class << self
      def register(context)
        token = SecureRandom.uuid
        mutex.synchronize do
          state = job_state(context)
          active_jobs[token] = state
          started_since_bucket << { token: token, context: state[:context] }
          started_since_bucket.shift(started_since_bucket.length - STARTED_JOB_LIMIT) if started_since_bucket.length > STARTED_JOB_LIMIT
          start_thread unless sampler_thread&.alive?
        end
        token
      rescue StandardError => e
        log_failure(e)
        nil
      end

      def unregister(token)
        return unless token

        state = mutex.synchronize { active_jobs.delete(token) }
        return unless state

        sample = read_sample
        update_peak(state, sample)
        state[:end_rss_bytes] = sample[:rss_bytes]
        state[:end_cgroup_memory_current_bytes] = sample[:cgroup_memory_current_bytes]
        persist!(summary_event(state))
      rescue StandardError => e
        log_failure(e)
      end

      def sample!
        jobs, started_entries = mutex.synchronize do
          return if active_jobs.empty?

          [ active_jobs.values, started_since_bucket.dup ]
        end
        sample = read_sample
        jobs.each { |state| update_peak(state, sample) }
        bucket = coarse_bucket(sample)
        return unless mutex.synchronize { bucket_crossed?(bucket) }

        mutex.synchronize do
          return unless bucket_crossed?(bucket)

          @high_water_bucket = high_water_bucket.zip(bucket).map(&:max)
          @started_since_bucket -= started_entries
        end
        persist!(threshold_event(sample, jobs, started_entries, bucket))
      rescue StandardError => e
        log_failure(e)
      end

      def reset!
        thread = mutex.synchronize do
          previous = @sampler_thread
          @sampler_thread = nil
          @active_jobs = {}
          @started_since_bucket = []
          @high_water_bucket = [ 0, 0 ]
          previous
        end
        thread&.kill
      end

      private

      def mutex = (@mutex ||= Mutex.new)
      def active_jobs = (@active_jobs ||= {})
      def started_since_bucket = (@started_since_bucket ||= [])
      def sampler_thread = @sampler_thread
      def high_water_bucket = (@high_water_bucket ||= [ 0, 0 ])

      def start_thread
        @sampler_thread = Thread.new do
          Thread.current.name = "syrus-memory-high-water" if Thread.current.respond_to?(:name=)
          Thread.current.report_on_exception = false
          loop do
            sleep SAMPLE_INTERVAL
            sample!
            break if retire_thread_if_idle(Thread.current)
          end
        ensure
          mutex.synchronize do
            next unless Thread.current == @sampler_thread

            @sampler_thread = nil
            start_thread if active_jobs.any?
          end
        end
      end

      def retire_thread_if_idle(thread)
        mutex.synchronize do
          return false unless active_jobs.empty?

          @sampler_thread = nil if sampler_thread == thread
          true
        end
      end

      def job_state(context)
        {
          context: PerformanceLogging.safe_context(context),
          started_at: Time.current,
          start_rss_bytes: nil,
          start_cgroup_memory_current_bytes: nil,
          peak_rss_bytes: nil,
          peak_cgroup_memory_current_bytes: nil
        }
      end

      def read_sample
        {
          rss_bytes: ProcessResourceSampler.rss_bytes,
          cgroup_memory_current_bytes: RunProcessParallelism.cgroup_memory_current_bytes,
          cgroup_memory_limit_bytes: RunProcessParallelism.effective_memory_limit_bytes,
          cgroup_memory_events: RunProcessParallelism.cgroup_memory_events,
          heap_live_slots: GC.stat(:heap_live_slots)
        }
      end

      def coarse_bucket(sample)
        byte_bucket = [ sample[:rss_bytes], sample[:cgroup_memory_current_bytes] ].compact.max.to_i / BUCKET_BYTES
        limit = sample[:cgroup_memory_limit_bytes]
        usage = sample[:cgroup_memory_current_bytes]
        percentage_bucket = if limit&.positive? && usage
          LIMIT_PERCENTAGES.count { |threshold| usage >= limit * threshold }
        else
          0
        end
        [ byte_bucket, percentage_bucket ]
      end


      def bucket_crossed?(bucket)
        bucket.zip(high_water_bucket).any? { |current, previous| current > previous }
      end

      def update_peak(state, sample)
        mutex.synchronize do
          state[:start_rss_bytes] ||= sample[:rss_bytes]
          state[:start_cgroup_memory_current_bytes] ||= sample[:cgroup_memory_current_bytes]
          state[:peak_rss_bytes] = [ state[:peak_rss_bytes], sample[:rss_bytes] ].compact.max
          state[:peak_cgroup_memory_current_bytes] = [ state[:peak_cgroup_memory_current_bytes], sample[:cgroup_memory_current_bytes] ].compact.max
        end
      end

      def threshold_event(sample, jobs, started_entries, bucket)
        PerformanceLogging.base_event(MEMORY_HIGH_WATER_EVENT).merge(
          sample.transform_keys(&:to_s),
          "bucket" => bucket,
          "active_jobs" => jobs.map { |state| state[:context] },
          "jobs_started_since_previous_bucket" => started_entries.map { |entry| entry[:context] }
        ).compact
      end

      def summary_event(state)
        PerformanceLogging.base_event(JOB_MEMORY_SUMMARY_EVENT).merge(
          state[:context],
          "started_at" => state[:started_at].iso8601(6),
          "ended_at" => Time.current.iso8601(6),
          "start_rss_bytes" => state[:start_rss_bytes],
          "end_rss_bytes" => state[:end_rss_bytes],
          "peak_rss_bytes" => state[:peak_rss_bytes],
          "start_cgroup_memory_current_bytes" => state[:start_cgroup_memory_current_bytes],
          "end_cgroup_memory_current_bytes" => state[:end_cgroup_memory_current_bytes],
          "peak_cgroup_memory_current_bytes" => state[:peak_cgroup_memory_current_bytes]
        ).compact
      end

      def persist!(event)
        PerformanceLogging.suppress do
          PerformanceLogEvent.create!(PerformanceLogEvent.from_event_hash(event))
        end
      end

      def log_failure(error)
        Rails.logger.error("[PerformanceLogging::MemoryHighWaterSampler] #{error.class}: #{error.message}")
      rescue StandardError
        nil
      end
    end
  end
end
