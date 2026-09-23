require "rails_helper"

RSpec.describe Admin::McpStartupTimingPayload do
  def record!(phase:, at:, chat_session_id: 1, chat_message_id: 1, provider: nil, server_name: nil)
    McpStartupPhaseEvent.create!(
      McpStartupPhaseEvent.from_event_hash(
        "occurred_at" => at.iso8601(6),
        "phase" => phase,
        "source" => McpStartupTiming::SOURCE_BY_PHASE.fetch(phase),
        "provider" => provider,
        "server_name" => server_name,
        "chat_session_id" => chat_session_id,
        "chat_message_id" => chat_message_id
      )
    )
  end

  it "reports per-phase elapsed-since-start latency distributions" do
    base = Time.zone.parse("2026-09-20 12:00:00")
    record!(phase: "agent_process_spawn", at: base, provider: "claude")
    record!(phase: "sidecar_process_spawn", at: base + 0.2.seconds, server_name: "syrus-chat-sidecar")
    record!(phase: "first_assistant_message", at: base + 2.seconds)

    payload = described_class.new(params: { start: (base - 1.hour).iso8601, end: (base + 1.hour).iso8601 }).as_json

    latency = payload.fetch(:phase_latency)
    spawn_row = latency.find { |row| row[:phase] == "agent_process_spawn" }
    reply_row = latency.find { |row| row[:phase] == "first_assistant_message" }

    expect(spawn_row).to include(count: 1, avg_ms: 0.0, p50_ms: 0.0, p95_ms: 0.0, max_ms: 0.0)
    expect(reply_row).to include(count: 1, avg_ms: 2000.0, max_ms: 2000.0)
    expect(payload.fetch(:turns_observed)).to eq(1)
    expect(payload.fetch(:stalled_turns)).to eq(0)
  end

  it "counts a turn that never reaches first_assistant_message as stalled" do
    base = Time.zone.parse("2026-09-20 12:00:00")
    record!(phase: "agent_process_spawn", at: base, chat_session_id: 9, chat_message_id: 9)
    record!(phase: "sidecar_process_spawn", at: base + 1.second, chat_session_id: 9, chat_message_id: 9, server_name: "syrus-chat-sidecar")

    payload = described_class.new(params: { start: (base - 1.hour).iso8601, end: (base + 1.hour).iso8601 }).as_json

    expect(payload.fetch(:turns_observed)).to eq(1)
    expect(payload.fetch(:stalled_turns)).to eq(1)
  end

  it "keeps a turn's turn-scoped phases visible even when filtering by a server name only some of its phases carry" do
    base = Time.zone.parse("2026-09-20 12:00:00")
    record!(phase: "agent_process_spawn", at: base, chat_session_id: 2, chat_message_id: 2, provider: "claude")
    record!(phase: "sidecar_process_spawn", at: base + 1.second, chat_session_id: 2, chat_message_id: 2, server_name: "syrus-chat-sidecar")
    # Unrelated turn on a different server -- must not leak into the filtered result.
    record!(phase: "agent_process_spawn", at: base, chat_session_id: 3, chat_message_id: 3, provider: "claude")
    record!(phase: "sidecar_process_spawn", at: base + 1.second, chat_session_id: 3, chat_message_id: 3, server_name: "syrus-chat-deferred-sidecar")

    payload = described_class.new(params: {
      start: (base - 1.hour).iso8601, end: (base + 1.hour).iso8601, server_name: "syrus-chat-sidecar"
    }).as_json

    expect(payload.fetch(:turns_observed)).to eq(1)
    phases = payload.fetch(:phase_latency).map { |row| row[:phase] }
    expect(phases).to include("agent_process_spawn", "sidecar_process_spawn")
  end

  it "excludes events outside the requested window" do
    base = Time.zone.parse("2026-09-20 12:00:00")
    record!(phase: "agent_process_spawn", at: base - 2.days)

    payload = described_class.new(params: { start: (base - 1.hour).iso8601, end: (base + 1.hour).iso8601 }).as_json

    expect(payload.fetch(:turns_observed)).to eq(0)
    expect(payload.fetch(:phase_latency)).to eq([])
  end
end
