module Throughput
  # Instance-wide, bucketed throughput series for the admin diagnostics API.
  #
  # This intentionally does not reuse `Throughput::MetricContract`: that
  # contract answers "what is the current rate over these rolling windows
  # (1h/4h/24h/7d/last_active) for one repository?", computed once per
  # request from in-memory arrays. This class answers a different shape of
  # question -- "how did instance-wide (or one repository's) throughput move
  # bucket by bucket across an arbitrary `since`/`until` range?" -- which
  # needs grouped counts per bucket rather than a handful of window totals.
  class AdminMetricsPayload
    VERSION = 1
    DEFAULT_WINDOW = 7.days
    MAX_WINDOW = 90.days
    HOUR_SECONDS = 1.hour.to_i
    DAY_SECONDS = 1.day.to_i

    # Jobs have no durable "reached implemented" timestamp column -- the
    # AASM transition is not event-logged. The successful `pr_open` Step's
    # `finished_at` is the closest durable proxy: it is the moment
    # `Steps::PrOpen` (or the reconciler/auto-approval paths that mirror it)
    # calls `mark_implemented!` for the overwhelming majority of Jobs. A Job
    # that reaches `implemented` through another path without ever running a
    # successful `pr_open` Step (e.g. certain reconciliation repairs) is not
    # counted here.
    IMPLEMENTED_PROXY_STEP_KIND = "pr_open".freeze

    def initialize(repository: nil, since: nil, until_time: nil, now: Time.current)
      @repository = repository
      @until_time = parse_time(until_time) || now
      requested_since = parse_time(since) || (@until_time - DEFAULT_WINDOW)
      @since = [ requested_since, @until_time - MAX_WINDOW ].max
      @since = @until_time if @since > @until_time
    end

    def as_json(*)
      {
        version: VERSION,
        generated_at: Time.current.iso8601,
        range: { since: since.iso8601, until: until_time.iso8601 },
        repository: repository ? { id: repository.id, slug: repository.slug } : nil,
        hourly: granularity_payload(HOUR_SECONDS),
        daily: granularity_payload(DAY_SECONDS)
      }
    end

    private

    attr_reader :repository, :since, :until_time

    def granularity_payload(duration_seconds)
      created_by_bucket = counts_by_bucket(created_ats, duration_seconds)
      closed_by_bucket = counts_by_bucket(closed_ats, duration_seconds)
      implemented_by_bucket = counts_by_bucket(implemented_ats, duration_seconds)
      cycle_time_by_bucket = durations_by_bucket(merged_cycle_time_pairs, duration_seconds)

      {
        bucket_seconds: duration_seconds,
        buckets: bucket_starts(duration_seconds).map do |bucket_start|
          bucket_payload(bucket_start, duration_seconds, created_by_bucket, closed_by_bucket, implemented_by_bucket, cycle_time_by_bucket)
        end
      }
    end

    # Per-bucket resilience: one bucket's stats failing to compute (e.g. an
    # unexpected value slipping past the type-safe pluck) emits
    # `error_serializing` for that bucket instead of 500ing the whole
    # response, mirroring `Admin::JobStateSerializer#per_record_error`.
    def bucket_payload(bucket_start, duration_seconds, created_by_bucket, closed_by_bucket, implemented_by_bucket, cycle_time_by_bucket)
      {
        bucket_start: bucket_start.iso8601,
        bucket_end: (bucket_start + duration_seconds).iso8601,
        jobs_created: created_by_bucket.fetch(bucket_start, 0),
        jobs_closed: closed_by_bucket.fetch(bucket_start, 0),
        jobs_implemented: implemented_by_bucket.fetch(bucket_start, 0),
        cycle_time_seconds: duration_stat(cycle_time_by_bucket.fetch(bucket_start, []))
      }
    rescue => e
      Rails.logger.warn(
        "[throughput/admin_metrics_payload] failed to serialize bucket #{bucket_start.iso8601}: " \
        "#{e.class}: #{e.message}"
      )
      { bucket_start: bucket_start.iso8601, error_serializing: "#{e.class}: #{e.message}" }
    end

    def bucket_starts(duration_seconds)
      first = floor_to(since, duration_seconds)
      last = floor_to(until_time, duration_seconds)
      starts = []
      cursor = first
      while cursor <= last
        starts << cursor
        cursor += duration_seconds
      end
      starts
    end

    def counts_by_bucket(timestamps, duration_seconds)
      timestamps.compact.group_by { |time| floor_to(time, duration_seconds) }.transform_values(&:size)
    end

    def durations_by_bucket(pairs, duration_seconds)
      pairs
        .reject { |(created_at, finished_at)| created_at.nil? || finished_at.nil? }
        .group_by { |(_created_at, finished_at)| floor_to(finished_at, duration_seconds) }
        .transform_values { |group| group.map { |(created_at, finished_at)| finished_at - created_at } }
    end

    def duration_stat(values)
      {
        sample_count: values.size,
        median: percentile(values, 0.5),
        p90: percentile(values, 0.9)
      }
    end

    def percentile(values, target_percentile)
      return nil if values.empty?

      sorted = values.sort
      sorted[((sorted.size - 1) * target_percentile).ceil].round
    end

    def floor_to(time, duration_seconds)
      Time.zone.at((time.to_f / duration_seconds).floor * duration_seconds)
    end

    def created_ats
      @created_ats ||= jobs_scope.where(created_at: since..until_time).pluck(:created_at)
    end

    # `Job::TERMINAL_STATES` also includes the legacy `no_change_needed`
    # state. Current no-change closures land in `state: "closed"` with
    # `closure_reason: "no_changes"` (see `Job#mark_no_change_needed`'s own
    # comment); `no_change_needed` rows are old/operator-forced repair
    # transitions and are intentionally not counted as "closed" here.
    def closed_ats
      @closed_ats ||= jobs_scope.where(state: "closed").where(finished_at: since..until_time).pluck(:finished_at)
    end

    def implemented_ats
      @implemented_ats ||= begin
        scope = Step.joins(workflow: :job)
          .where(kind: IMPLEMENTED_PROXY_STEP_KIND, state: "succeeded")
          .where(finished_at: since..until_time)
        scope = scope.where(jobs: { repository_id: repository.id }) if repository
        # One event per Job: the first successful pr_open completion.
        scope.group("workflows.job_id").minimum(:finished_at).values
      end
    end

    def merged_cycle_time_pairs
      @merged_cycle_time_pairs ||= jobs_scope
        .where(state: "closed", closure_reason: "pr_merged")
        .where(finished_at: since..until_time)
        .pluck(:created_at, :finished_at)
    end

    def jobs_scope
      repository ? Job.where(repository_id: repository.id) : Job.all
    end

    def parse_time(value)
      return value if value.respond_to?(:iso8601)
      return nil if value.blank?

      Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end
  end
end
