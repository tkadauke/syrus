# A single observed milestone in a chat turn's MCP startup lifecycle (see
# McpStartupTiming). Append-only and durable: rows persist via
# Observability::EventSink so a phase recorded by a short-lived MCP sidecar
# subprocess survives that process exiting before the periodic flush would
# otherwise have picked it up.
class McpStartupPhaseEvent < ApplicationRecord
  include ObservabilityEventRecord

  RETENTION = 14.days

  belongs_to :chat_session, optional: true
  belongs_to :chat_message, optional: true
  belongs_to :run, optional: true

  attribute :metadata, :json, default: -> { {} }

  validates :occurred_at, :phase, :source, presence: true
  validates :phase, inclusion: { in: McpStartupTiming::PHASES }

  before_validation { self.metadata ||= {} }
  before_update { raise ActiveRecord::ReadOnlyRecord, "McpStartupPhaseEvent is append-only" }
  before_destroy { raise ActiveRecord::ReadOnlyRecord, "McpStartupPhaseEvent is append-only" unless destroyed_by_association }

  scope :expired, -> { where(occurred_at: ...RETENTION.ago) }
  scope :for_turn, ->(chat_session_id:, chat_message_id:) {
    where(chat_session_id: chat_session_id, chat_message_id: chat_message_id)
  }

  def self.from_event_hash(event)
    attrs = event.to_h
    {
      occurred_at: parse_event_time(attrs["occurred_at"]) || Time.current,
      phase: attrs["phase"],
      source: attrs["source"],
      provider: attrs["provider"],
      server_name: attrs["server_name"],
      tier: attrs["tier"],
      chat_session_id: attrs["chat_session_id"],
      chat_message_id: attrs["chat_message_id"],
      run_id: attrs["run_id"],
      hostname: attrs["hostname"],
      pid: attrs["pid"],
      app_revision: attrs["app_revision"],
      metadata: normalized_event_json(attrs["metadata"]),
      created_at: Time.current,
      updated_at: Time.current
    }.compact
  end

  def self.persist_observability_events!(rows, batch_size:)
    deduped_rows = rows.uniq { |row| dedupe_key(row) }
    return if deduped_rows.empty?

    deduped_rows.each_slice(batch_size) do |batch|
      insert_all(normalize_insert_rows(batch)) # rubocop:disable Rails/SkipsModelValidations
    end
  end

  def self.dedupe_key(row)
    [ row[:phase], row[:server_name], row[:chat_session_id], row[:chat_message_id], row[:run_id] ]
  end

  def self.normalize_insert_rows(rows)
    keys = rows.flat_map(&:keys).uniq
    rows.map { |row| keys.index_with { |key| row[key] } }
  end

  def as_event_hash
    {
      "event" => "syrus.mcp_startup_phase",
      "occurred_at" => occurred_at&.iso8601(6),
      "phase" => phase,
      "source" => source,
      "provider" => provider,
      "server_name" => server_name,
      "tier" => tier,
      "chat_session_id" => chat_session_id,
      "chat_message_id" => chat_message_id,
      "run_id" => run_id,
      "hostname" => hostname,
      "pid" => pid,
      "app_revision" => app_revision,
      "metadata" => metadata
    }.compact
  end

  def self.as_recent_event_hashes(limit:)
    recent_first.limit(limit).map(&:as_event_hash)
  end

  # Identifies the chat turn a phase event belongs to. Used to group raw
  # phase rows back into per-turn waterfalls (see Admin::McpStartupTimingPayload)
  # without a SQL self-join.
  def turn_key
    [ chat_session_id, chat_message_id ]
  end

  # The earliest phase (in McpStartupTiming::PHASES canonical order) with no
  # recorded row for this turn/server -- i.e. the phase the lifecycle never
  # reached. `server_name` narrows to one sidecar (essential vs. deferred)
  # when the caller knows which one stalled; omit it to look across all
  # servers recorded for the turn. Turn-scoped phases (agent_process_spawn,
  # required_server_ready, first_assistant_message) carry no server_name of
  # their own, so they are always included alongside whichever server is
  # being checked rather than filtered out by the narrowing.
  def self.stalled_phase_for(chat_session_id:, chat_message_id:, server_name: nil)
    scope = for_turn(chat_session_id: chat_session_id, chat_message_id: chat_message_id)
    scope = scope.where(server_name: [ nil, server_name ]) if server_name.present?
    observed = scope.distinct.pluck(:phase).to_set

    McpStartupTiming::PHASES.find { |phase| !observed.include?(phase) }
  end
end
