module Admin
  class WorkerHealthPayload
    DEFAULT_WINDOW = 24.hours
    CURRENT_SAMPLE_WINDOW = 15.minutes
    SAMPLE_LIMIT_PER_HOST = 12
    DEFAULT_MINUTE_BUCKET_WINDOW = 1.hour
    MAX_MINUTE_BUCKET_WINDOW = 24.hours
    TREND_WINDOWS = {
      "15m" => 15.minutes,
      "1h" => 1.hour,
      "6h" => 6.hours,
      "24h" => 24.hours
    }.freeze

    def initialize(hostname: nil, since: nil, until_time: nil, sample_limit_per_host: SAMPLE_LIMIT_PER_HOST, minute_bucket_window_minutes: DEFAULT_MINUTE_BUCKET_WINDOW / 1.minute)
      @hostname = hostname.presence
      @until_time = parse_time(until_time) || Time.current
      @since = parse_time(since) || (@until_time - DEFAULT_WINDOW)
      @sample_limit_per_host = sample_limit_per_host.to_i.clamp(0, 100)
      @minute_bucket_window = minute_bucket_window_minutes.to_i.minutes.clamp(0.seconds, MAX_MINUTE_BUCKET_WINDOW)
    end

    def as_json(*)
      {
        generated_at: Time.current.iso8601,
        range: {
          since: since.iso8601,
          until: until_time.iso8601
        },
        current_sample_window_seconds: CURRENT_SAMPLE_WINDOW.to_i,
        minute_bucket: {
          granularity_seconds: 1.minute.to_i,
          window_minutes: (minute_bucket_window / 1.minute).to_i,
          max_window_minutes: (MAX_MINUTE_BUCKET_WINDOW / 1.minute).to_i
        },
        current: current_workers,
        hosts: host_history
      }
    end

    private

    attr_reader :hostname, :since, :until_time, :sample_limit_per_host, :minute_bucket_window

    def current_workers
      @current_workers ||= InstanceVersion.fresh.where(role: "worker").then { |scope|
        hostname ? scope.where(hostname: hostname) : scope
      }.order(:hostname).map do |instance|
        latest = latest_sample_by_hostname[instance.hostname]
        payload = instance_payload(instance, latest)
        payload[:trend] = summarize(samples_for(instance.hostname).select { |sample| sample.observed_at >= 1.hour.ago })
        payload
      end
    end

    def host_history
      hostnames = (samples.map(&:hostname) + current_workers.map { |worker| worker.fetch(:hostname) }).compact.uniq.sort
      hostnames.map do |host|
        host_samples = samples_for(host)
        {
          hostname: host,
          current: current_workers.find { |worker| worker.fetch(:hostname) == host },
          windows: TREND_WINDOWS.transform_values { |duration| summarize(host_samples.select { |sample| sample.observed_at >= until_time - duration }) },
          minute_buckets: minute_buckets(host_samples),
          recent_samples: host_samples.first(sample_limit_per_host).map { |sample| sample_payload(sample) }
        }
      end
    end

    def instance_payload(instance, latest)
      health = health_for(sample: latest, instance: instance)
      {
        id: instance.id,
        hostname: instance.hostname,
        role: instance.role,
        version: instance.version,
        started_at: instance.started_at&.iso8601,
        last_heartbeat_at: instance.last_heartbeat_at&.iso8601,
        seconds_since_heartbeat: instance.seconds_since_heartbeat,
        stale: instance.stale?,
        health: health,
        sample: latest ? sample_payload(latest) : nil
      }
    end

    def sample_payload(sample)
      {
        id: sample.id,
        hostname: sample.hostname,
        role: sample.role,
        version: sample.version,
        observed_at: sample.observed_at&.iso8601,
        cpu_used_percent: sample.cpu_used_percent,
        load_1m: sample.load_1m,
        load_5m: sample.load_5m,
        load_15m: sample.load_15m,
        memory_used_percent: sample.memory_used_percent,
        memory_available_bytes: sample.memory_available_bytes,
        memory_total_bytes: sample.memory_total_bytes,
        data_root_used_percent: sample.data_root_used_percent,
        data_root_available_bytes: sample.data_root_available_bytes,
        data_root_total_bytes: sample.data_root_total_bytes,
        cpu_pressure_some: sample.cpu_pressure_some,
        cpu_pressure_full: sample.cpu_pressure_full,
        io_pressure_some: sample.io_pressure_some,
        io_pressure_full: sample.io_pressure_full,
        raw_metrics: sample.raw_metrics || {}
      }
    end

    def summarize(host_samples)
      host_samples = host_samples.compact
      return empty_summary if host_samples.empty?

      {
        sample_count: host_samples.length,
        first_observed_at: host_samples.last.observed_at&.iso8601,
        last_observed_at: host_samples.first.observed_at&.iso8601,
        cpu_used_percent: numeric_summary(host_samples, :cpu_used_percent),
        memory_used_percent: numeric_summary(host_samples, :memory_used_percent),
        data_root_used_percent: numeric_summary(host_samples, :data_root_used_percent),
        load_1m: numeric_summary(host_samples, :load_1m),
        load_5m: numeric_summary(host_samples, :load_5m),
        load_15m: numeric_summary(host_samples, :load_15m),
        cpu_pressure_some: numeric_summary(host_samples, :cpu_pressure_some),
        cpu_pressure_full: numeric_summary(host_samples, :cpu_pressure_full),
        io_pressure_some: numeric_summary(host_samples, :io_pressure_some),
        io_pressure_full: numeric_summary(host_samples, :io_pressure_full),
        warning_count: host_samples.count { |sample| health_for(sample: sample).fetch(:level) == "warning" },
        critical_count: host_samples.count { |sample| health_for(sample: sample).fetch(:level) == "critical" }
      }
    end

    def minute_buckets(host_samples)
      return [] if minute_bucket_window.zero?

      bucket_end = floor_minute(until_time)
      requested_bucket_count = (minute_bucket_window / 1.minute).to_i
      bucket_start = [ floor_minute(since), bucket_end - (requested_bucket_count - 1).minutes ].max
      samples_by_minute = host_samples
        .select { |sample| sample.observed_at >= bucket_start && sample.observed_at <= until_time }
        .group_by { |sample| floor_minute(sample.observed_at) }

      buckets = []
      minute = bucket_start
      while minute <= bucket_end
        buckets << minute_bucket_payload(minute, samples_by_minute.fetch(minute, []))
        minute += 1.minute
      end
      buckets
    end

    def minute_bucket_payload(minute, host_samples)
      summarize(host_samples).merge(minute: minute.iso8601)
    end

    def empty_summary
      {
        sample_count: 0,
        first_observed_at: nil,
        last_observed_at: nil,
        warning_count: 0,
        critical_count: 0
      }
    end

    def numeric_summary(host_samples, field)
      values = host_samples.filter_map { |sample| sample.public_send(field) }
      return nil if values.empty?

      {
        avg: (values.sum.to_f / values.length).round(2),
        max: values.max.round(2)
      }
    end

    def health_for(sample:, instance: nil)
      reasons = []
      level = "ok"

      if instance&.stale?
        level = "critical"
        reasons << "worker heartbeat stale"
      end

      if sample.nil?
        return { level: level == "critical" ? "critical" : "unknown", reasons: reasons.presence || [ "no recent host health sample" ] }
      end

      if sample.observed_at < CURRENT_SAMPLE_WINDOW.ago
        level = max_level(level, "warning")
        reasons << "host health sample older than #{CURRENT_SAMPLE_WINDOW.to_i} seconds"
      end

      level, reasons = apply_threshold(level, reasons, "cpu", sample.cpu_used_percent, warning: 90, critical: 98)
      level, reasons = apply_threshold(level, reasons, "memory", sample.memory_used_percent, warning: 85, critical: 95)
      level, reasons = apply_threshold(level, reasons, "data root disk", sample.data_root_used_percent, warning: DataRootDiskUsage::WARNING_USED_PERCENT, critical: DataRootDiskUsage::CRITICAL_USED_PERCENT)
      level, reasons = apply_threshold(level, reasons, "CPU pressure", sample.cpu_pressure_some, warning: 20, critical: 50)
      level, reasons = apply_threshold(level, reasons, "IO pressure", sample.io_pressure_some, warning: 20, critical: 50)

      { level: level, reasons: reasons }
    end

    def apply_threshold(level, reasons, label, value, warning:, critical:)
      return [ level, reasons ] if value.nil?

      if value >= critical
        [ max_level(level, "critical"), reasons + [ "#{label} #{value.round(2)}% >= #{critical}%" ] ]
      elsif value >= warning
        [ max_level(level, "warning"), reasons + [ "#{label} #{value.round(2)}% >= #{warning}%" ] ]
      else
        [ level, reasons ]
      end
    end

    def max_level(left, right)
      order = { "unknown" => 0, "ok" => 1, "warning" => 2, "critical" => 3 }
      order.fetch(left) >= order.fetch(right) ? left : right
    end

    def latest_sample_by_hostname
      @latest_sample_by_hostname ||= samples.group_by(&:hostname).transform_values(&:first)
    end

    def floor_minute(value)
      Time.zone.at((value.to_f / 60).floor * 60)
    end

    def samples_for(host)
      samples_by_hostname.fetch(host, [])
    end

    def samples_by_hostname
      @samples_by_hostname ||= samples.group_by(&:hostname)
    end

    def samples
      @samples ||= WorkerHostHealthSample
        .where(observed_at: since..until_time)
        .then { |scope| hostname ? scope.where(hostname: hostname) : scope }
        .order(observed_at: :desc)
        .to_a
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
