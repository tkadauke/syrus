require "rails_helper"

RSpec.describe McpStartupPhaseEvent do
  describe ".from_event_hash" do
    it "builds insertable attributes from a raw event hash" do
      attrs = described_class.from_event_hash(
        "occurred_at" => "2026-09-22T12:00:00.000000Z",
        "phase" => "tool_inventory_received",
        "source" => "sidecar",
        "provider" => "claude",
        "server_name" => "syrus-chat-sidecar",
        "tier" => "essential",
        "chat_session_id" => 3,
        "chat_message_id" => 4,
        "metadata" => { "duration_ms" => 12.5 }
      )

      expect(attrs).to include(
        phase: "tool_inventory_received",
        source: "sidecar",
        provider: "claude",
        server_name: "syrus-chat-sidecar",
        tier: "essential",
        chat_session_id: 3,
        chat_message_id: 4,
        metadata: { "duration_ms" => 12.5 }
      )
      expect(attrs[:occurred_at]).to eq(Time.zone.parse("2026-09-22T12:00:00.000000Z"))
    end
  end

  it "is append-only" do
    event = described_class.create!(
      described_class.from_event_hash(
        "occurred_at" => Time.current.iso8601,
        "phase" => "agent_process_spawn",
        "source" => "agent"
      )
    )

    expect { event.update!(phase: "first_assistant_message") }.to raise_error(ActiveRecord::ReadOnlyRecord)
  end

  it "rejects a phase outside the canonical McpStartupTiming lifecycle" do
    event = described_class.new(
      occurred_at: Time.current,
      phase: "not_a_real_phase",
      source: "agent"
    )

    expect(event).not_to be_valid
    expect(event.errors[:phase]).to be_present
  end

  describe ".stalled_phase_for" do
    it "returns the earliest unrecorded canonical phase for the turn" do
      described_class.create!(described_class.from_event_hash(
        "occurred_at" => Time.current.iso8601, "phase" => "agent_process_spawn", "source" => "agent",
        "chat_session_id" => 1, "chat_message_id" => 2
      ))

      expect(described_class.stalled_phase_for(chat_session_id: 1, chat_message_id: 2)).to eq("sidecar_process_spawn")
    end

    it "returns nil once every phase for the turn has a row" do
      McpStartupTiming::PHASES.each do |phase|
        described_class.create!(described_class.from_event_hash(
          "occurred_at" => Time.current.iso8601, "phase" => phase, "source" => McpStartupTiming::SOURCE_BY_PHASE[phase],
          "chat_session_id" => 1, "chat_message_id" => 2
        ))
      end

      expect(described_class.stalled_phase_for(chat_session_id: 1, chat_message_id: 2)).to be_nil
    end

    it "does not exclude turn-scoped (server-less) phases when narrowed to one server" do
      described_class.create!(described_class.from_event_hash(
        "occurred_at" => Time.current.iso8601, "phase" => "agent_process_spawn", "source" => "agent",
        "chat_session_id" => 1, "chat_message_id" => 2
      ))
      described_class.create!(described_class.from_event_hash(
        "occurred_at" => Time.current.iso8601, "phase" => "sidecar_process_spawn", "source" => "sidecar",
        "server_name" => "syrus-chat-sidecar", "chat_session_id" => 1, "chat_message_id" => 2
      ))

      expect(described_class.stalled_phase_for(chat_session_id: 1, chat_message_id: 2, server_name: "syrus-chat-sidecar"))
        .to eq("sidecar_application_boot")
    end

    it "scopes strictly by chat_session_id and chat_message_id" do
      described_class.create!(described_class.from_event_hash(
        "occurred_at" => Time.current.iso8601, "phase" => "agent_process_spawn", "source" => "agent",
        "chat_session_id" => 1, "chat_message_id" => 999
      ))

      expect(described_class.stalled_phase_for(chat_session_id: 1, chat_message_id: 2)).to eq("agent_process_spawn")
    end
  end
end
