# Structured, queryable timing telemetry for the MCP startup lifecycle a
# chat turn's agent process and MCP sidecar go through: from the moment
# Syrus spawns the agent CLI to the moment the operator sees the first
# reply.
#
# Each phase is recorded as its own durable Observability event (persisted
# via McpStartupPhaseEvent), tagged by chat/message/server. That makes the
# full waterfall reconstructable with a single query even though the eight
# phases are observed from two different OS processes -- the ChatTurnJob
# worker ("agent"-sourced phases) and the spawned MCP sidecar
# ("sidecar"-sourced phases), see SOURCE_BY_PHASE -- and it is what backs
# per-phase latency distributions in the admin metrics UI (grouping
# McpStartupPhaseEvent rows by `phase`).
#
# Never pass tokens, credentials, or prompt/response content into `metadata`
# -- only identifiers (provider, server, tier, chat/message/run ids) belong
# here.
module McpStartupTiming
  # Canonical order. Also the order #stalled_phase_for walks to find the
  # first *missing* phase for a stalled or timed-out turn -- unambiguous
  # timeout attribution without needing to merge two processes' clocks.
  PHASES = %w[
    agent_process_spawn
    sidecar_process_spawn
    sidecar_application_boot
    initialize_request_received
    initialize_response_sent
    tool_inventory_received
    required_server_ready
    first_assistant_message
  ].freeze

  # Which side of the pipe observes each phase. Sidecar-sourced phases are
  # recorded by the short-lived MCP sidecar subprocess itself; agent-sourced
  # phases are recorded by the ChatTurnJob worker process driving the agent
  # CLI. Neither process can observe the other's phases directly -- that is
  # exactly why each phase is its own durable, independently-flushed event
  # rather than one record mutated in place.
  SOURCE_BY_PHASE = {
    "agent_process_spawn" => "agent",
    "sidecar_process_spawn" => "sidecar",
    "sidecar_application_boot" => "sidecar",
    "initialize_request_received" => "sidecar",
    "initialize_response_sent" => "sidecar",
    "tool_inventory_received" => "sidecar",
    "required_server_ready" => "agent",
    "first_assistant_message" => "agent"
  }.freeze

  def self.record!(phase:, provider: nil, server_name: nil, tier: nil,
                   chat_session_id: nil, chat_message_id: nil, run_id: nil,
                   occurred_at: Time.current, metadata: {})
    phase = phase.to_s
    # A caller passing an unknown phase is a programmer error, not a runtime
    # telemetry hiccup -- raise it plainly instead of swallowing it in the
    # `rescue` below, which exists only to stop a telemetry-plumbing failure
    # (e.g. the observability sink erroring) from ever failing a chat turn.
    raise ArgumentError, "unknown MCP startup phase: #{phase.inspect}" unless PHASES.include?(phase)

    record_event!(phase: phase, provider: provider, server_name: server_name, tier: tier,
                  chat_session_id: chat_session_id, chat_message_id: chat_message_id, run_id: run_id,
                  occurred_at: occurred_at, metadata: metadata)
  end

  def self.record_event!(phase:, provider:, server_name:, tier:, chat_session_id:, chat_message_id:,
                         run_id:, occurred_at:, metadata:)
    event = {
      "event" => "syrus.mcp_startup_phase",
      "occurred_at" => occurred_at.utc.iso8601(6),
      "phase" => phase,
      "source" => SOURCE_BY_PHASE.fetch(phase),
      "provider" => provider.to_s.presence,
      "server_name" => server_name.to_s.presence,
      "tier" => tier.to_s.presence,
      "chat_session_id" => as_id(chat_session_id),
      "chat_message_id" => as_id(chat_message_id),
      "run_id" => as_id(run_id),
      "hostname" => SyrusVersion.hostname,
      "pid" => Process.pid,
      "app_revision" => SyrusVersion.current,
      "metadata" => safe_metadata(metadata)
    }.compact

    Rails.logger.info("[mcp_startup] #{log_line(event)}")
    Observability::EventSink.append(kind: :mcp_startup_phase, event: event, durable: true)
    event
  rescue StandardError => e
    Rails.logger.warn("[McpStartupTiming] record failed phase=#{phase}: #{e.class}: #{e.message}")
    nil
  end
  private_class_method :record_event!

  # The earliest canonical phase this turn (optionally scoped to one
  # sidecar server) never reached -- unambiguous attribution for a timed
  # out or failed startup. Flushes the durable stream first so phases
  # recorded moments ago by a since-exited sidecar subprocess are visible
  # to this (different) process's read.
  def self.stalled_phase_for(chat_session_id:, chat_message_id:, server_name: nil)
    Observability::EventSink.flush!(kinds: [ :mcp_startup_phase ])
    McpStartupPhaseEvent.stalled_phase_for(
      chat_session_id: chat_session_id,
      chat_message_id: chat_message_id,
      server_name: server_name
    )
  end

  def self.log_stalled_phase!(chat_session_id:, chat_message_id:, server_name: nil)
    phase = stalled_phase_for(
      chat_session_id: chat_session_id,
      chat_message_id: chat_message_id,
      server_name: server_name
    )
    if phase
      Rails.logger.warn(
        "[mcp_startup] stalled chat_id=#{chat_session_id} message_id=#{chat_message_id} " \
        "server=#{server_name} phase=#{phase}"
      )
    end
    phase
  rescue StandardError => e
    Rails.logger.warn("[McpStartupTiming] stalled-phase lookup failed: #{e.class}: #{e.message}")
    nil
  end

  def self.as_id(value)
    Integer(value, exception: false)
  end
  private_class_method :as_id

  def self.safe_metadata(metadata)
    metadata.to_h.transform_keys(&:to_s).transform_values do |value|
      value.is_a?(String) ? value.truncate(500) : value
    end
  end
  private_class_method :safe_metadata

  def self.log_line(event)
    event.except("event", "metadata").map { |key, value| "#{key}=#{value}" }.join(" ")
  end
  private_class_method :log_line
end
