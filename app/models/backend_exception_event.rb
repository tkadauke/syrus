class BackendExceptionEvent < ApplicationRecord
  include ObservabilityEventRecord

  RETENTION = 14.days
  MAX_SHORT_TEXT_BYTES = 500
  MAX_MESSAGE_BYTES = 2_000
  MAX_STACK_BYTES = 20_000

  belongs_to :job, optional: true
  belongs_to :workflow, optional: true
  belongs_to :run, optional: true

  attribute :metadata, :json, default: -> { {} }

  validates :occurred_at, :fingerprint, :source, :exception_class, :message, presence: true

  scope :expired, -> { where(occurred_at: ...RETENTION.ago) }

  before_validation :normalize_payload
  before_update { raise ActiveRecord::ReadOnlyRecord, "BackendExceptionEvent is append-only" }
  before_destroy { raise ActiveRecord::ReadOnlyRecord, "BackendExceptionEvent is append-only" unless destroyed_by_association }

  def self.record_request!(payload, duration_ms)
    exception_class, exception_message = Array(payload[:exception])
    exception = payload[:exception_object]
    return if exception_class.blank? && exception.nil?

    request = payload[:request]
    create!(
      occurred_at: Time.current,
      source: "action_controller",
      role: "web",
      request_id: request&.request_id || payload[:request_id],
      exception_class: exception_class || exception.class.name,
      message: exception_message || exception&.message,
      backtrace: formatted_backtrace(exception),
      controller: payload[:controller],
      action: payload[:action],
      method: payload[:method],
      path: payload[:path],
      status: payload[:status],
      metadata: {
        format: payload[:format],
        duration_ms: duration_ms.to_f.round(1)
      }.compact_blank
    )
  end

  def self.record_job!(payload, duration_ms)
    exception_class, exception_message = Array(payload[:exception])
    exception = payload[:exception_object]
    return if exception_class.blank? && exception.nil?

    job = payload[:job]
    current_run = Thread.current[:syrus_current_run]
    create!(
      occurred_at: Time.current,
      source: "active_job",
      role: "worker",
      request_id: nil,
      exception_class: exception_class || exception.class.name,
      message: exception_message || exception&.message,
      backtrace: formatted_backtrace(exception),
      job_class: job&.class&.name || payload[:job_class],
      active_job_id: job&.job_id,
      queue_name: job&.queue_name,
      executions: job&.executions,
      job_id: current_run&.job_id,
      workflow_id: current_run&.workflow_id,
      run_id: current_run&.id,
      metadata: {
        duration_ms: duration_ms.to_f.round(1)
      }
    )
  end

  def self.formatted_backtrace(exception)
    backtrace = exception&.backtrace
    return if backtrace.blank?

    cleaned = Rails.backtrace_cleaner.clean(backtrace)
    cleaned = backtrace if cleaned.blank?
    cleaned.first(50).join("\n")
  end

  private_class_method :formatted_backtrace

  private

  def normalize_payload
    self.occurred_at ||= Time.current
    self.app_revision = clean_string(app_revision.presence || SyrusVersion.current, MAX_SHORT_TEXT_BYTES)
    self.source = clean_string(source, MAX_SHORT_TEXT_BYTES).presence || "unknown"
    self.role = clean_string(role.presence || OperationalLogging.process_role, MAX_SHORT_TEXT_BYTES)
    self.hostname = clean_string(hostname.presence || SyrusVersion.hostname, MAX_SHORT_TEXT_BYTES)
    self.request_id = clean_string(request_id, MAX_SHORT_TEXT_BYTES)
    self.exception_class = clean_string(exception_class, MAX_SHORT_TEXT_BYTES).presence || "Exception"
    self.message = clean_string(message, MAX_MESSAGE_BYTES).presence || "Unknown backend exception"
    self.backtrace = clean_string(backtrace, MAX_STACK_BYTES)
    self.controller = clean_string(controller, MAX_SHORT_TEXT_BYTES)
    self.action = clean_string(action, MAX_SHORT_TEXT_BYTES)
    self.method = clean_string(method, MAX_SHORT_TEXT_BYTES)
    self.path = clean_string(path, MAX_STACK_BYTES)
    self.status = Integer(status, exception: false)
    self.job_class = clean_string(job_class, MAX_SHORT_TEXT_BYTES)
    self.active_job_id = clean_string(active_job_id, MAX_SHORT_TEXT_BYTES)
    self.queue_name = clean_string(queue_name, MAX_SHORT_TEXT_BYTES)
    self.executions = Integer(executions, exception: false)
    self.metadata = bounded_hash(metadata)
    self.fingerprint = clean_string(fingerprint, MAX_SHORT_TEXT_BYTES).presence || fallback_fingerprint
  end

  def fallback_fingerprint
    Digest::SHA256.hexdigest([ source, exception_class, message, backtrace.to_s.lines.first ].compact.join("\n"))[0, 64]
  end

  def clean_string(value, limit)
    OperationalLogging.redact(Mcp::Tools.utf8(value).gsub(/[[:space:]]+/, " ").strip).safe_byteslice(0, limit)
  end

  def bounded_hash(value)
    self.class.normalized_event_json(value).first(50).to_h.transform_values { |child| bounded_value(child) }
  end

  def bounded_value(value)
    case value
    when Hash
      value.first(20).to_h.transform_values { |child| bounded_value(child) }
    when Array
      value.first(20).map { |child| bounded_value(child) }
    else
      clean_string(value, MAX_SHORT_TEXT_BYTES)
    end
  end
end
