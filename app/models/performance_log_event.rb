class PerformanceLogEvent < ApplicationRecord
  include ObservabilityEventRecord

  RETENTION = 6.hours

  attribute :payload, :json, default: -> { {} }

  validates :occurred_at, :event_name, presence: true

  scope :expired, -> { where(occurred_at: ...RETENTION.ago) }

  def self.from_event_hash(event)
    attrs = event.to_h
    now = Time.current
    {
      occurred_at: parse_event_time(attrs["occurred_at"]) || Time.current,
      app_revision: attrs["app_revision"],
      event_name: attrs["event"],
      request_id: attrs["request_id"],
      method: attrs["method"],
      path: attrs["path"],
      controller: attrs["controller"],
      action: attrs["action"],
      phase: attrs["phase"],
      name: attrs["name"],
      trace_id: attrs["trace_id"],
      sql_fingerprint: attrs["fingerprint"].to_s.safe_byteslice(0, 700).presence,
      duration_ms: attrs["duration_ms"],
      sql_count: attrs["sql_count"],
      sql_duration_ms: attrs["sql_duration_ms"],
      slow_sql_count: attrs["slow_sql_count"],
      payload: compact_payload(attrs),
      created_at: now,
      updated_at: now
    }
  end

  def as_event_hash
    payload.to_h.merge(
      "occurred_at" => occurred_at&.iso8601(6),
      "app_revision" => app_revision,
      "event" => event_name,
      "request_id" => request_id,
      "method" => method,
      "path" => path,
      "controller" => controller,
      "action" => action,
      "phase" => phase,
      "name" => name,
      "trace_id" => trace_id,
      "fingerprint" => sql_fingerprint,
      "duration_ms" => duration_ms,
      "sql_count" => sql_count,
      "sql_duration_ms" => sql_duration_ms,
      "slow_sql_count" => slow_sql_count
    ).compact
  end

  def self.as_recent_event_hashes(limit:)
    recent_first.limit(limit).map(&:as_event_hash)
  end

  def self.compact_payload(attrs)
    {
      "format" => attrs["format"],
      "status" => attrs["status"],
      "view_runtime_ms" => attrs["view_runtime_ms"],
      "db_runtime_ms" => attrs["db_runtime_ms"],
      "visibility_state" => attrs["visibility_state"],
      "metadata" => compact_metadata(attrs["metadata"]),
      "api_requests" => compact_api_requests(attrs["api_requests"]),
      "top_sql_fingerprints" => compact_top_sql_fingerprints(attrs["top_sql_fingerprints"])
    }.compact_blank
  end

  def self.compact_metadata(value)
    value.to_h.transform_values { |entry| entry.to_s.safe_byteslice(0, 300) }.presence
  rescue StandardError
    nil
  end

  def self.compact_api_requests(value)
    Array(value).first(10).filter_map do |entry|
      attrs = entry.to_h
      {
        "name" => attrs["name"].to_s.safe_byteslice(0, 100),
        "path" => attrs["path"].to_s.safe_byteslice(0, 300),
        "request_id" => attrs["request_id"].to_s.safe_byteslice(0, 100),
        "duration_ms" => attrs["duration_ms"],
        "status" => attrs["status"]
      }.compact_blank
    end.presence
  end

  def self.compact_top_sql_fingerprints(value)
    Array(value).first(5).filter_map do |entry|
      attrs = entry.to_h
      {
        "fingerprint" => attrs["fingerprint"].to_s.safe_byteslice(0, 300),
        "sample_sql" => attrs["sample_sql"].to_s.safe_byteslice(0, 600),
        "name" => attrs["name"].to_s.safe_byteslice(0, 100),
        "count" => attrs["count"],
        "total_duration_ms" => attrs["total_duration_ms"],
        "max_duration_ms" => attrs["max_duration_ms"]
      }.compact_blank
    end.presence
  end
end
