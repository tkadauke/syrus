class BrowserErrorEvent < ApplicationRecord
  include ObservabilityEventRecord

  RETENTION = 14.days
  MAX_SHORT_TEXT_BYTES = 500
  MAX_MESSAGE_BYTES = 2_000
  MAX_STACK_BYTES = 20_000
  MAX_RECENT_ITEMS = 20

  belongs_to :user

  attribute :route_params, :json, default: -> { {} }
  attribute :viewport, :json, default: -> { {} }
  attribute :feature_flags, :json, default: -> { {} }
  attribute :recent_api_requests, :json, default: -> { [] }
  attribute :recent_errors, :json, default: -> { [] }
  attribute :metadata, :json, default: -> { {} }

  validates :occurred_at, :fingerprint, :message, presence: true

  scope :expired, -> { where(occurred_at: ...RETENTION.ago) }

  before_validation :normalize_payload
  before_update { raise ActiveRecord::ReadOnlyRecord, "BrowserErrorEvent is append-only" }
  before_destroy { raise ActiveRecord::ReadOnlyRecord, "BrowserErrorEvent is append-only" unless destroyed_by_association }

  def self.record!(user:, payload:)
    attrs = payload.respond_to?(:to_unsafe_h) ? payload.to_unsafe_h : payload.to_h
    create!(
      user: user,
      occurred_at: parse_event_time(attrs["occurred_at"] || attrs[:occurred_at]) || Time.current,
      app_revision: attrs["app_revision"] || attrs[:app_revision] || SyrusVersion.current,
      fingerprint: attrs["fingerprint"] || attrs[:fingerprint],
      name: attrs["name"] || attrs[:name],
      message: attrs["message"] || attrs[:message],
      stack: attrs["stack"] || attrs[:stack],
      component_stack: attrs["component_stack"] || attrs[:component_stack],
      url: attrs["url"] || attrs[:url],
      path: attrs["path"] || attrs[:path],
      route_id: attrs["route_id"] || attrs[:route_id],
      route_params: attrs["route_params"] || attrs[:route_params],
      trace_id: attrs["trace_id"] || attrs[:trace_id],
      user_agent: attrs["user_agent"] || attrs[:user_agent],
      viewport: attrs["viewport"] || attrs[:viewport],
      feature_flags: attrs["feature_flags"] || attrs[:feature_flags],
      recent_api_requests: attrs["recent_api_requests"] || attrs[:recent_api_requests],
      recent_errors: attrs["recent_errors"] || attrs[:recent_errors],
      metadata: attrs["metadata"] || attrs[:metadata]
    )
  end

  private

  def normalize_payload
    self.app_revision = clean_string(app_revision, MAX_SHORT_TEXT_BYTES)
    self.fingerprint = clean_string(fingerprint, MAX_SHORT_TEXT_BYTES).presence || fallback_fingerprint
    self.name = clean_string(name, MAX_SHORT_TEXT_BYTES)
    self.message = clean_string(message, MAX_MESSAGE_BYTES).presence || "Unknown browser error"
    self.stack = clean_string(stack, MAX_STACK_BYTES)
    self.component_stack = clean_string(component_stack, MAX_STACK_BYTES)
    self.url = clean_string(url, MAX_STACK_BYTES)
    self.path = clean_string(path, MAX_SHORT_TEXT_BYTES)
    self.route_id = clean_string(route_id, MAX_SHORT_TEXT_BYTES)
    self.trace_id = clean_string(trace_id, MAX_SHORT_TEXT_BYTES)
    self.user_agent = clean_string(user_agent, MAX_MESSAGE_BYTES)
    self.route_params = bounded_hash(route_params, value_bytes: MAX_SHORT_TEXT_BYTES)
    self.viewport = bounded_hash(viewport, value_bytes: MAX_SHORT_TEXT_BYTES)
    self.feature_flags = bounded_hash(feature_flags, value_bytes: MAX_SHORT_TEXT_BYTES)
    self.recent_api_requests = bounded_array(recent_api_requests, value_bytes: MAX_SHORT_TEXT_BYTES)
    self.recent_errors = bounded_array(recent_errors, value_bytes: MAX_SHORT_TEXT_BYTES)
    self.metadata = bounded_hash(metadata, value_bytes: MAX_SHORT_TEXT_BYTES)
  end

  def fallback_fingerprint
    Digest::SHA256.hexdigest([ name, message, stack ].compact.join("\n"))[0, 64]
  end

  def clean_string(value, limit)
    Mcp::Tools.utf8(value).gsub(/[[:space:]]+/, " ").strip.safe_byteslice(0, limit)
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
