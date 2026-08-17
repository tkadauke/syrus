module BackendExceptionLogging
  module_function

  def ingest_request(payload, duration_ms)
    return if ignored_request?(payload)

    BackendExceptionEvent.record_request!(payload, duration_ms)
  rescue StandardError => e
    Rails.logger.error("[BackendExceptionLogging] request exception event dropped: #{e.class}: #{e.message}")
    nil
  end

  def ingest_job(payload, duration_ms)
    return if ignored_job?(payload)

    BackendExceptionEvent.record_job!(payload, duration_ms)
  rescue StandardError => e
    Rails.logger.error("[BackendExceptionLogging] job exception event dropped: #{e.class}: #{e.message}")
    nil
  end

  def ignored_request?(payload)
    OperationalLogging.ignored_request?(payload)
  end

  def ignored_job?(payload)
    OperationalLogging.ignored_job?(payload[:job], payload)
  end
end
