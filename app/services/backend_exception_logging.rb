module BackendExceptionLogging
  EXPECTED_JOB_EXCEPTION_CLASSES = [
    "Steps::Base::StepFailed"
  ].freeze

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
    expected_job_exception?(payload) || OperationalLogging.ignored_job?(payload[:job], payload)
  end

  def expected_job_exception?(payload)
    exception = payload[:exception_object]
    return true if expected_exception_object?(exception)

    exception_class, = Array(payload[:exception])
    expected_exception_class_name?(exception_class)
  end

  def expected_exception_object?(exception)
    return false if exception.nil?

    EXPECTED_JOB_EXCEPTION_CLASSES.any? do |class_name|
      klass = class_name.safe_constantize
      klass && exception.is_a?(klass)
    end
  end

  def expected_exception_class_name?(exception_class)
    return false if exception_class.blank?

    klass = exception_class.to_s.safe_constantize
    EXPECTED_JOB_EXCEPTION_CLASSES.any? do |class_name|
      expected = class_name.safe_constantize
      exception_class.to_s == class_name || (klass && expected && klass <= expected)
    end
  end
end
