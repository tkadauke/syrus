module OperationalLogging
  FEATURE_SLUG = :operational_log_indexing
  MAX_MESSAGE_BYTES = 4_000
  MAX_CONTEXT_BYTES = 8_000
  PRUNE_INTERVAL = 10.minutes
  SECRET_FILTERS = [
    /(authorization:\s*bearer\s+)[^\s,;]+/i,
    /((?:password|passwd|secret|token|api[_-]?key)=)[^&\s]+/i,
    /((?:access|refresh|id)_token["']?\s*[:=]\s*["']?)[^"',\s}]+/i
  ].freeze

  module_function

  def enabled_for_instance?
    return false if suppressed?
    return true if Current.operational_log_indexing_enabled == true

    enabled = configured_for_instance?
    Current.operational_log_indexing_enabled = true if enabled
    enabled
  end

  def configured_for_instance?
    feature_enabled? && syrus_repository_registered?
  end

  def ingest(level:, source:, message:, occurred_at: Time.current, context: {}, role: nil, hostname: nil, pid: Process.pid)
    return unless enabled_for_instance?

    suppress do
      attrs = normalized_context(context)
      event = OperationalLogEvent.create!(
        occurred_at: occurred_at,
        level: normalize_level(level),
        role: safe_string(role.presence || process_role, 100),
        hostname: safe_string(hostname.presence || SyrusVersion.hostname, 255),
        app_revision: safe_string(SyrusVersion.current, 255),
        pid: pid,
        source: safe_string(source, 255),
        request_id: safe_string(attrs.delete("request_id"), 255),
        job_id: integer_or_nil(attrs.delete("job_id")),
        workflow_id: integer_or_nil(attrs.delete("workflow_id")),
        run_id: integer_or_nil(attrs.delete("run_id")),
        message: safe_string(message, MAX_MESSAGE_BYTES),
        context: attrs
      )
      enqueue_prune_if_due
      event
    end
  rescue StandardError
    nil
  end

  def ingest_request(payload, duration_ms)
    return if ignored_request?(payload)

    request = payload[:request]
    status = payload[:status].to_i
    ingest(
      level: status >= 500 || payload[:exception].present? ? "error" : "info",
      role: "web",
      source: "action_controller",
      message: "#{payload[:method]} #{payload[:path]} #{status} #{duration_ms.to_f.round(1)}ms",
      context: {
        request_id: request&.request_id || payload[:request_id],
        method: payload[:method],
        path: payload[:path],
        controller: payload[:controller],
        action: payload[:action],
        format: payload[:format],
        status: status,
        duration_ms: duration_ms.to_f.round(1),
        exception: Array(payload[:exception]).first
      }.compact_blank
    )
  end

  def ingest_job(payload, duration_ms, level: "info")
    job = payload[:job]
    return if ignored_job?(job, payload)

    current_run = Thread.current[:syrus_current_run]
    ingest(
      level: payload[:exception].present? ? "error" : level,
      role: "worker",
      source: "active_job",
      message: "#{job&.class&.name || payload[:job_class]} #{duration_ms.to_f.round(1)}ms",
      context: {
        active_job_id: job&.job_id,
        job_class: job&.class&.name || payload[:job_class],
        queue_name: job&.queue_name,
        executions: job&.executions,
        exception: Array(payload[:exception]).first,
        job_id: current_run&.job_id,
        workflow_id: current_run&.workflow_id,
        run_id: current_run&.id
      }.compact_blank
    )
  end

  def suppress
    previous = Thread.current[:syrus_operational_logging_suppressed]
    Thread.current[:syrus_operational_logging_suppressed] = true
    yield
  ensure
    Thread.current[:syrus_operational_logging_suppressed] = previous
  end

  def suppressed?
    Thread.current[:syrus_operational_logging_suppressed]
  end

  def feature_enabled?
    suppress { Feature.operational_log_indexing_enabled? }
  rescue StandardError
    false
  end

  def syrus_repository_registered?
    suppress do
      Repository.active.any? do |repository|
        McpToolPolicy.syrus_repository?(repository)
      end
    end
  rescue StandardError
    false
  end

  def process_role
    ENV["SYRUS_PROCESS_ROLE"].presence ||
      ENV["RAILS_PROCESS_ROLE"].presence ||
      (ENV["SYRUS_MCP_SIDECAR"].present? || ENV["SYRUS_CHAT_MCP_SIDECAR"].present? ? "mcp_sidecar" : "rails")
  end

  def ignored_request?(payload)
    path = payload[:path].to_s
    path.start_with?(
      "/api/v1/admin/performance",
      "/api/v1/app/admin/performance",
      "/api/v1/app/admin/operational_logs"
    )
  end

  def ignored_job?(job, payload)
    job_class = job&.class&.name || payload[:job_class].to_s
    job_class.in?([ "IndexOperationalLogEventJob", "PruneOperationalLogsJob" ])
  end

  def normalize_level(level)
    level = level.to_s.downcase
    OperationalLogEvent::LEVELS.include?(level) ? level : "unknown"
  end

  def normalized_context(context)
    raw = context.to_h.to_h do |key, value|
      [ safe_string(key, 100), safe_string(redact(value), 1_000) ]
    end.compact_blank

    JSON.parse(safe_string(raw.to_json, MAX_CONTEXT_BYTES))
  rescue JSON::ParserError
    {}
  end

  def redact(value)
    text = value.to_s
    SECRET_FILTERS.reduce(text) { |current, pattern| current.gsub(pattern, "\\1[REDACTED]") }
  end

  def safe_string(value, limit)
    redact(Mcp::Tools.utf8(value).gsub(/[[:space:]]+/, " ").strip).safe_byteslice(0, limit)
  end

  def integer_or_nil(value)
    Integer(value, exception: false)
  end

  def enqueue_prune_if_due
    last = Thread.current[:syrus_operational_log_last_prune_enqueue_at]
    return if last && Time.current - last < PRUNE_INTERVAL

    Thread.current[:syrus_operational_log_last_prune_enqueue_at] = Time.current
    PruneOperationalLogsJob.perform_later
  end
end
