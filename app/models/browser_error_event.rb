class BrowserErrorEvent < ApplicationRecord
  include ObservabilityEventRecord

  RETENTION = 14.days
  MAX_SHORT_TEXT_BYTES = 500
  MAX_MESSAGE_BYTES = 2_000
  MAX_STACK_BYTES = 20_000
  MAX_RECENT_ITEMS = 20
  MAX_RESOURCE_TIMINGS = 8
  RECOVERABLE_BURST_WINDOW = 30.seconds

  belongs_to :user

  attribute :route_params, :json, default: -> { {} }
  attribute :viewport, :json, default: -> { {} }
  attribute :feature_flags, :json, default: -> { {} }
  attribute :recent_api_requests, :json, default: -> { [] }
  attribute :recent_errors, :json, default: -> { [] }
  attribute :metadata, :json, default: -> { {} }
  attribute :error_cause, :json, default: -> { {} }
  attribute :last_interaction, :json, default: -> { {} }
  attribute :resource_timings, :json, default: -> { [] }

  validates :occurred_at, :fingerprint, :message, presence: true

  scope :expired, -> { where(occurred_at: ...RETENTION.ago) }

  before_validation :normalize_payload
  before_update { raise ActiveRecord::ReadOnlyRecord, "BrowserErrorEvent is append-only" }
  before_destroy { raise ActiveRecord::ReadOnlyRecord, "BrowserErrorEvent is append-only" unless destroyed_by_association }
  after_create_commit :enqueue_index
  after_create_commit :enqueue_auto_report, if: -> { Feature.browser_error_auto_reports_enabled? }

  def self.record!(user:, payload:)
    create!(record_attributes(user: user, payload: payload))
  end

  def self.record_or_merge!(user:, payload:)
    candidate = new(record_attributes(user: user, payload: payload))
    candidate.valid?
    return candidate.tap(&:save!) unless candidate.recoverable?

    transaction do
      canonical = lock
        .where(
          user: user,
          recoverable: true,
          fingerprint: candidate.fingerprint,
          app_revision: candidate.app_revision,
          path: candidate.path,
          last_occurred_at: (candidate.occurred_at - RECOVERABLE_BURST_WINDOW)..candidate.occurred_at
        )
        .order(last_occurred_at: :desc)
        .first

      canonical ? canonical.merge_recoverable_occurrence!(candidate) : candidate.tap(&:save!)
    end
  end

  def self.record_attributes(user:, payload:)
    raw = payload.respond_to?(:to_unsafe_h) ? payload.to_unsafe_h : payload.to_h
    attrs = Observability::EventPayloadSanitizer.sanitize(raw.deep_symbolize_keys)
    occurred_at = parse_event_time(attrs[:occurred_at]) || Time.current
    {
      user: user,
      occurred_at: occurred_at,
      last_occurred_at: occurred_at,
      app_revision: attrs[:app_revision] || SyrusVersion.current,
      fingerprint: attrs[:fingerprint],
      name: attrs[:name],
      message: attrs[:message],
      stack: attrs[:stack],
      component_stack: attrs[:component_stack],
      component_stack_unavailable_reason: attrs[:component_stack_unavailable_reason],
      error_cause: attrs[:error_cause],
      url: attrs[:url], path: attrs[:path], route_id: attrs[:route_id], route_params: attrs[:route_params],
      trace_id: attrs[:trace_id], correlation_id: attrs[:correlation_id], user_agent: attrs[:user_agent],
      viewport: attrs[:viewport], feature_flags: attrs[:feature_flags],
      recent_api_requests: attrs[:recent_api_requests], recent_errors: attrs[:recent_errors],
      last_interaction: attrs[:last_interaction], resource_timings: attrs[:resource_timings],
      recoverable: ActiveModel::Type::Boolean.new.cast(attrs[:recoverable]) || false, metadata: attrs[:metadata]
    }
  end

  def merge_recoverable_occurrence!(candidate)
    candidate.valid?
    latest_at = [last_occurred_at, candidate.occurred_at].compact.max
    update_columns(
      occurrence_count: occurrence_count + 1,
      burst_duration_ms: ((latest_at - occurred_at) * 1_000).round,
      last_occurred_at: latest_at,
      component_stack: component_stack.presence || candidate.component_stack,
      component_stack_unavailable_reason: component_stack.present? ? nil : candidate.component_stack_unavailable_reason,
      error_cause: candidate.error_cause.presence || error_cause,
      last_interaction: candidate.last_interaction.presence || last_interaction,
      resource_timings: candidate.resource_timings.presence || resource_timings,
      updated_at: Time.current
    )
    self
  end

  private

  def normalize_payload
    self.app_revision = clean_string(app_revision, MAX_SHORT_TEXT_BYTES)
    self.fingerprint = clean_string(fingerprint, MAX_SHORT_TEXT_BYTES).presence || fallback_fingerprint
    self.name = clean_string(name, MAX_SHORT_TEXT_BYTES)
    self.message = clean_string(message, MAX_MESSAGE_BYTES).presence || "Unknown browser error"
    self.stack = clean_string(stack, MAX_STACK_BYTES)
    self.component_stack = clean_string(component_stack, MAX_STACK_BYTES)
    self.component_stack_unavailable_reason = clean_string(component_stack_unavailable_reason, MAX_SHORT_TEXT_BYTES)
    self.url = clean_string(url, MAX_STACK_BYTES)
    self.path = clean_string(path, MAX_SHORT_TEXT_BYTES)
    self.route_id = clean_string(route_id, MAX_SHORT_TEXT_BYTES)
    self.trace_id = clean_string(trace_id, MAX_SHORT_TEXT_BYTES)
    self.correlation_id = clean_string(correlation_id, MAX_SHORT_TEXT_BYTES)
    self.user_agent = clean_string(user_agent, MAX_MESSAGE_BYTES)
    self.route_params = bounded_hash(route_params, value_bytes: MAX_SHORT_TEXT_BYTES)
    self.viewport = bounded_hash(viewport, value_bytes: MAX_SHORT_TEXT_BYTES)
    self.feature_flags = bounded_hash(feature_flags, value_bytes: MAX_SHORT_TEXT_BYTES)
    self.recent_api_requests = bounded_array(recent_api_requests, value_bytes: MAX_SHORT_TEXT_BYTES)
    self.recent_errors = bounded_array(recent_errors, value_bytes: MAX_SHORT_TEXT_BYTES)
    self.metadata = bounded_hash(metadata, value_bytes: MAX_SHORT_TEXT_BYTES)
    self.error_cause = bounded_hash(error_cause, value_bytes: MAX_MESSAGE_BYTES)
    self.last_interaction = bounded_hash(last_interaction, value_bytes: MAX_SHORT_TEXT_BYTES)
    self.resource_timings = Array.wrap(resource_timings).first(MAX_RESOURCE_TIMINGS).map { |child| bounded_value(child, value_bytes: MAX_SHORT_TEXT_BYTES) }
    self.occurrence_count = [occurrence_count.to_i, 1].max
    self.burst_duration_ms = [burst_duration_ms.to_i, 0].max
    self.last_occurred_at ||= occurred_at
  end

  def fallback_fingerprint
    Digest::SHA256.hexdigest([ name, message, stack ].compact.join("\n"))[0, 64]
  end

  def clean_string(value, limit)
    Mcp::Tools.utf8(value).gsub(/[[:space:]]+/, " ").strip.safe_byteslice(0, limit)
  end

  def enqueue_index
    IndexBrowserErrorEventsJob.perform_later([ id ])
  end

  def enqueue_auto_report
    BrowserErrorAutoReportJob.perform_later(id)
  end

  def bounded_hash(value, value_bytes:)
    normalized = self.class.normalized_event_json(value)
    normalized.first(50).to_h.transform_values { |child| bounded_value(child, value_bytes: value_bytes) }
  end

  def bounded_array(value, value_bytes:)
    Array.wrap(value).first(MAX_RECENT_ITEMS).map { |child| bounded_value(child, value_bytes: value_bytes) }
  end

  def bounded_value(value, value_bytes:)
    case value
    when Hash
      value.first(20).to_h.transform_values { |child| bounded_value(child, value_bytes: value_bytes) }
    when Array
      value.first(20).map { |child| bounded_value(child, value_bytes: value_bytes) }
    else
      clean_string(value, value_bytes)
    end
  end
end
