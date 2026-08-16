module PerformanceLogging
  FEATURE_SLUG = :performance_logging
  SLOW_REQUEST_EVENT = "syrus.performance.slow_request"
  SLOW_SQL_EVENT = "syrus.performance.slow_sql"
  SLOW_PHASE_EVENT = "syrus.performance.slow_phase"
  BROWSER_TRACE_EVENT = "syrus.performance.browser_trace"

  DEFAULT_SLOW_REQUEST_MS = 1_000.0
  DEFAULT_SLOW_SQL_MS = 250.0
  DEFAULT_SLOW_PHASE_MS = 250.0
  TOP_SQL_FINGERPRINT_LIMIT = Integer(ENV["SYRUS_PERFORMANCE_TOP_SQL_FINGERPRINT_LIMIT"], exception: false) || 8
  MAX_SQL_FINGERPRINTS_PER_REQUEST = Integer(ENV["SYRUS_PERFORMANCE_MAX_SQL_FINGERPRINTS_PER_REQUEST"], exception: false) || 25
  # Multiple of a caller's byte limit that `safe_string` will scan before
  # collapsing whitespace. Whitespace collapsing can only shrink a string,
  # so the headroom keeps the post-collapse result full for realistic
  # inputs while still bounding the regexp against pathological ones.
  SAFE_STRING_SCAN_HEADROOM = 4

  module Store
    CACHE_KEY = "observability:performance_log_events"
    MAX_EVENTS = Integer(ENV["SYRUS_PERFORMANCE_MAX_EVENTS"], exception: false) || 300
    EXPIRES_IN = 6.hours
    FLUSH_INTERVAL = (Integer(ENV["SYRUS_PERFORMANCE_FLUSH_INTERVAL_SECONDS"], exception: false) || 60).seconds

    @mutex = Mutex.new
    @events = []
    @last_flush_at = Time.current

    module_function

    def append(event)
      Observability::EventSink.append(kind: :performance, event: event)
    rescue StandardError
      nil
    end

    def recent(limit: MAX_EVENTS)
      PerformanceLogging.suppress { Observability::EventSink.recent(kind: :performance, limit: clamp_limit(limit)) }
    rescue StandardError
      []
    end

    def flush!
      PerformanceLogging.suppress { Observability::EventSink.flush!(kinds: [ :performance ]) }
    rescue StandardError
      nil
    end

    def clear!
      PerformanceLogging.suppress { Observability::EventSink.clear!(kind: :performance) }
    rescue StandardError
      nil
    end

    def clamp_limit(limit)
      [[limit.to_i, 1].max, MAX_EVENTS].min
    end
  end

  module_function

  def with_request_context(context)
    Current.performance_request_context = safe_context(context)
    Current.performance_sql_count = 0
    Current.performance_sql_duration_ms = 0.0
    Current.performance_slow_sql_count = 0
    Current.performance_sql_fingerprints = {}
    Current.performance_phase_stack = []
    yield
  end

  def merge_request_context(context)
    Current.performance_request_context = request_context.merge(safe_context(context))
  end

  def enabled?
    return false if suppressed?
    return Current.performance_logging_enabled unless Current.performance_logging_enabled.nil?

    Current.performance_logging_enabled = if Rails.env.production?
      feature_enabled?
    else
      env_enabled? || feature_enabled?
    end
  end

  def record_sql(payload, duration_ms)
    return if suppressed? || ignored_sql?(payload)
    return unless enabled?

    Current.performance_sql_count = Current.performance_sql_count.to_i + 1
    Current.performance_sql_duration_ms = Current.performance_sql_duration_ms.to_f + duration_ms.to_f
    record_sql_fingerprint(payload, duration_ms)
    record_phase_sql(payload, duration_ms)
    return if duration_ms.to_f < slow_sql_threshold_ms

    Current.performance_slow_sql_count = Current.performance_slow_sql_count.to_i + 1
    Current.performance_phase_stack&.last&.then { |phase_entry| phase_entry["slow_sql_count"] += 1 }
    emit(
      base_event(SLOW_SQL_EVENT).merge(
        request_context,
        "duration_ms" => rounded_duration(duration_ms),
        "name" => safe_string(payload[:name], 200),
        "sql" => safe_string(payload[:sql], 600),
        "fingerprint" => fingerprint_sql(payload[:sql])
      ).compact
    )
  end

  def record_request(payload, duration_ms)
    return if suppressed?
    return if ignored_request?(payload)
    return unless enabled?
    return if duration_ms.to_f < slow_request_threshold_ms

    emit(
      base_event(SLOW_REQUEST_EVENT).merge(
        request_context_from_payload(payload),
        "duration_ms" => rounded_duration(duration_ms),
        "method" => safe_string(payload[:method], 20),
        "path" => safe_string(payload[:path], 500),
        "controller" => safe_string(payload[:controller], 200),
        "action" => safe_string(payload[:action], 100),
        "format" => safe_string(payload[:format], 50),
        "status" => payload[:status],
        "view_runtime_ms" => rounded_duration(payload[:view_runtime]),
        "db_runtime_ms" => rounded_duration(payload[:db_runtime]),
        "sql_count" => Current.performance_sql_count.to_i,
        "sql_duration_ms" => rounded_duration(Current.performance_sql_duration_ms),
        "slow_sql_count" => Current.performance_slow_sql_count.to_i,
        "top_sql_fingerprints" => top_sql_fingerprints
      ).compact
    )
  end

  def phase(name, metadata = {})
    return yield unless enabled?

    phase_entry = {
      "phase" => safe_string(name, 200),
      "sql_count" => 0,
      "sql_duration_ms" => 0.0,
      "slow_sql_count" => 0,
      "sql_fingerprints" => {}
    }
    phase_stack = Current.performance_phase_stack ||= []
    phase_stack.push(phase_entry)
    started_at = monotonic_ms
    yield
  ensure
    duration_ms = monotonic_ms - started_at if started_at
    phase_stack&.delete(phase_entry) if phase_entry
    if duration_ms && duration_ms >= slow_phase_threshold_ms
      emit(
        base_event(SLOW_PHASE_EVENT).merge(
          request_context,
          "duration_ms" => rounded_duration(duration_ms),
          "phase" => phase_entry&.fetch("phase", nil) || safe_string(name, 200),
          "metadata" => safe_metadata(metadata),
          "sql_count" => phase_entry&.fetch("sql_count", 0).to_i,
          "sql_duration_ms" => rounded_duration(phase_entry&.fetch("sql_duration_ms", 0.0)),
          "slow_sql_count" => phase_entry&.fetch("slow_sql_count", 0).to_i,
          "top_sql_fingerprints" => top_sql_fingerprints(phase_entry&.fetch("sql_fingerprints", {}))
        )
      )
    end
  end

  def plugin_call(extension_point:, provider:, operation:)
    phase(
      "plugin.#{extension_point}.#{operation}",
      extension_point: extension_point,
      provider: plugin_provider_name(provider),
      operation: operation
    ) { yield }
  end

  def record_browser_trace(payload)
    return unless enabled?

    attrs = payload.to_h
    duration_ms = rounded_duration(attrs[:duration_ms] || attrs["duration_ms"])
    event = base_event(BROWSER_TRACE_EVENT).merge(
      request_context,
      "duration_ms" => duration_ms,
      "trace_id" => safe_string(attrs[:trace_id] || attrs["trace_id"], 100),
      "name" => safe_string(attrs[:name] || attrs["name"], 200),
      "path" => safe_string(attrs[:path] || attrs["path"], 500),
      "visibility_state" => safe_string(attrs[:visibility_state] || attrs["visibility_state"], 50),
      "api_requests" => safe_api_requests(attrs[:api_requests] || attrs["api_requests"]),
      "spans" => safe_browser_spans(attrs[:spans] || attrs["spans"]),
      "metadata" => safe_metadata(attrs[:metadata] || attrs["metadata"] || {})
    ).compact
    emit(event, flush: false)
  end

  def slow_request_threshold_ms
    threshold_from_env("SYRUS_PERFORMANCE_SLOW_REQUEST_MS", DEFAULT_SLOW_REQUEST_MS)
  end

  def slow_sql_threshold_ms
    threshold_from_env("SYRUS_PERFORMANCE_SLOW_SQL_MS", DEFAULT_SLOW_SQL_MS)
  end

  def slow_phase_threshold_ms
    threshold_from_env("SYRUS_PERFORMANCE_SLOW_PHASE_MS", DEFAULT_SLOW_PHASE_MS)
  end

  def thresholds
    {
      slow_request_ms: slow_request_threshold_ms,
      slow_sql_ms: slow_sql_threshold_ms,
      slow_phase_ms: slow_phase_threshold_ms,
      top_sql_fingerprint_limit: TOP_SQL_FINGERPRINT_LIMIT,
      max_sql_fingerprints_per_request: MAX_SQL_FINGERPRINTS_PER_REQUEST
    }
  end

  def suppress
    previous = Thread.current[:syrus_performance_logging_suppressed]
    Thread.current[:syrus_performance_logging_suppressed] = true
    yield
  ensure
    Thread.current[:syrus_performance_logging_suppressed] = previous
  end

  def suppressed?
    Thread.current[:syrus_performance_logging_suppressed]
  end

  def feature_enabled?
    suppress { Feature.enabled?(FEATURE_SLUG) }
  rescue StandardError
    false
  end

  def env_enabled?
    ActiveModel::Type::Boolean.new.cast(ENV["SYRUS_PERFORMANCE_LOGGING"])
  end

  def ignored_sql?(payload)
    return true if payload[:cached] || payload[:name] == "SCHEMA"

    sql = payload[:sql].to_s
    name = payload[:name].to_s
    return true if observability_sql?(sql, name)

    sql.match?(/\A\s*(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE SAVEPOINT)\b/i)
  end

  def observability_sql?(sql, name)
    name.start_with?("PerformanceLogEvent ", "OperationalLogEvent ", "WorkflowActivityEvent ", "WorkEngineReconcilerActivityEvent ") ||
      sql.match?(/\b(?:performance_log_events|operational_log_events|workflow_activity_events|work_engine_reconciler_activity_events)\b/i)
  end

  def ignored_request?(payload)
    controller = payload[:controller].to_s
    return true if controller.in?([
      "Api::V1::Admin::PerformanceController",
      "Api::V1::App::Admin::PerformanceController"
    ])

    path = payload[:path].to_s
    path.start_with?("/api/v1/admin/performance", "/api/v1/app/admin/performance", "/api/v1/app/performance_events")
  end

  def emit(event, flush: true)
    Rails.logger.info(event.to_json)
    Store.append(event)
  rescue StandardError
    nil
  end

  def base_event(name)
    {
      "event" => name,
      "occurred_at" => Time.current.iso8601(6),
      "app_revision" => SyrusVersion.current,
      "pid" => Process.pid
    }
  end

  def plugin_provider_name(provider)
    if provider.respond_to?(:name)
      provider.name
    else
      provider.class.name
    end.presence || provider.to_s
  rescue StandardError
    provider.to_s
  end

  def request_context
    (Current.performance_request_context || {}).to_h
  end

  def request_context_from_payload(payload)
    request = payload[:request]
    request_context.merge(
      "request_id" => safe_string(request&.request_id || payload[:request_id] || request_context["request_id"], 100),
      "method" => safe_string(payload[:method] || request_context["method"], 20),
      "path" => safe_string(payload[:path] || request_context["path"], 500),
      "controller" => safe_string(payload[:controller] || request_context["controller"], 200),
      "action" => safe_string(payload[:action] || request_context["action"], 100)
    ).compact_blank
  end

  def safe_context(context)
    context.to_h.filter_map do |key, value|
      next if value.nil?

      sanitized = case key.to_sym
      when :admin
        ActiveModel::Type::Boolean.new.cast(value)
      when :user_id
        Integer(value, exception: false)
      when :request_id
        safe_string(value, 100)
      when :method
        safe_string(value, 20)
      when :path
        safe_string(value, 500)
      when :controller
        safe_string(value, 200)
      when :action
        safe_string(value, 100)
      else
        safe_string(value, 500)
      end
      [ key.to_s, sanitized ] unless sanitized.nil?
    end.to_h
  end

  def record_sql_fingerprint(payload, duration_ms)
    fingerprints = Current.performance_sql_fingerprints ||= {}
    add_sql_fingerprint(fingerprints, payload, duration_ms)
  end

  def record_phase_sql(payload, duration_ms)
    phase_entry = Current.performance_phase_stack&.last
    return unless phase_entry

    phase_entry["sql_count"] += 1
    phase_entry["sql_duration_ms"] += duration_ms.to_f
    add_sql_fingerprint(phase_entry["sql_fingerprints"], payload, duration_ms)
  end

  def add_sql_fingerprint(fingerprints, payload, duration_ms)
    fingerprint = fingerprint_sql(payload[:sql])
    return if fingerprint.blank?
    return if fingerprints.size >= MAX_SQL_FINGERPRINTS_PER_REQUEST && !fingerprints.key?(fingerprint)

    entry = fingerprints[fingerprint] ||= {
      "fingerprint" => fingerprint,
      "sample_sql" => safe_string(payload[:sql], 600),
      "name" => safe_string(payload[:name], 200),
      "count" => 0,
      "total_duration_ms" => 0.0,
      "max_duration_ms" => 0.0
    }
    duration = duration_ms.to_f
    entry["count"] += 1
    entry["total_duration_ms"] += duration
    entry["max_duration_ms"] = [ entry["max_duration_ms"], duration ].max
  end

  def top_sql_fingerprints(fingerprints = Current.performance_sql_fingerprints)
    (fingerprints || {}).to_h.values
      .sort_by { |entry| [ -entry["total_duration_ms"].to_f, -entry["count"].to_i, entry["fingerprint"].to_s ] }
      .first(TOP_SQL_FINGERPRINT_LIMIT)
      .map do |entry|
        entry.merge(
          "total_duration_ms" => rounded_duration(entry["total_duration_ms"]),
          "max_duration_ms" => rounded_duration(entry["max_duration_ms"])
        )
      end
  end

  def fingerprint_sql(sql)
    safe_string(sql, 4_000)
      .gsub(/\b0x[0-9a-f]+\b/i, "?")
      .gsub(/'(?:''|[^'])*'/, "?")
      .gsub(/"(?:\"\"|[^"])*"/, "?")
      .gsub(/\b\d+\b/, "?")
      .gsub(/\s+/, " ")
      .strip
      .safe_byteslice(0, 1_000)
  end

  # Bound the input before any regexp touches it. Ruby applies a global
  # Regexp timeout, and collapsing whitespace across a multi-megabyte
  # string (a large `IN (...)` list, a bulk INSERT) blows through it —
  # raising Regexp::TimeoutError out of instrumentation and killing the
  # job being measured. Slice with headroom first so ordinary inputs
  # collapse exactly as before, then trim to the caller's limit.
  def safe_string(value, limit)
    raw = value.to_s
    scan_limit = limit * SAFE_STRING_SCAN_HEADROOM
    raw = raw.safe_byteslice(0, scan_limit) if raw.bytesize > scan_limit
    raw.gsub(/[[:space:]]+/, " ").strip.safe_byteslice(0, limit)
  end

  def safe_metadata(metadata)
    metadata.to_h.to_h do |key, value|
      [ safe_string(key, 100), safe_string(value, 500) ]
    end
  end

  def safe_api_requests(requests)
    Array(requests).first(10).filter_map do |entry|
      values = entry.to_h
      {
        "name" => safe_string(values[:name] || values["name"], 100),
        "path" => safe_string(values[:path] || values["path"], 500),
        "request_id" => safe_string(values[:request_id] || values["request_id"], 100),
        "duration_ms" => rounded_duration(values[:duration_ms] || values["duration_ms"]),
        "status" => Integer(values[:status] || values["status"], exception: false)
      }.compact_blank
    end
  end

  def safe_browser_spans(spans)
    Array(spans).first(20).filter_map do |entry|
      values = entry.to_h
      duration_ms = rounded_duration(values[:duration_ms] || values["duration_ms"])
      next if duration_ms.nil?

      {
        "name" => safe_string(values[:name] || values["name"], 100),
        "duration_ms" => duration_ms,
        "started_at_ms" => rounded_duration(values[:started_at_ms] || values["started_at_ms"]),
        "metadata" => safe_metadata(values[:metadata] || values["metadata"] || {})
      }.compact_blank
    end
  end

  def rounded_duration(value)
    return nil if value.nil?

    value.to_f.round(1)
  end

  def threshold_from_env(name, fallback)
    Float(ENV.fetch(name, fallback))
  rescue ArgumentError, TypeError
    fallback
  end

  def monotonic_ms
    Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1_000.0
  end
end
