require "rails_helper"

RSpec.describe McpStartupTiming do
  describe ".record!" do
    it "persists a durable phase event tagged with provider, server, and turn identity" do
      described_class.record!(
        phase: "sidecar_process_spawn",
        provider: "claude",
        server_name: "syrus-chat-sidecar",
        tier: "essential",
        chat_session_id: 42,
        chat_message_id: 7,
        metadata: { note: "boot" }
      )
      Observability::EventSink.flush!(kinds: [ :mcp_startup_phase ])

      event = McpStartupPhaseEvent.sole
      expect(event).to have_attributes(
        phase: "sidecar_process_spawn",
        source: "sidecar",
        provider: "claude",
        server_name: "syrus-chat-sidecar",
        tier: "essential",
        chat_session_id: 42,
        chat_message_id: 7
      )
      expect(event.metadata).to eq("note" => "boot")
    end

    it "rejects a phase name outside the canonical lifecycle" do
      expect {
        described_class.record!(phase: "not_a_real_phase", chat_session_id: 1, chat_message_id: 1)
      }.to raise_error(ArgumentError, /unknown MCP startup phase/)
    end

    it "never raises when the observability sink fails, so a telemetry bug cannot fail a chat turn" do
      allow(Observability::EventSink).to receive(:append).and_raise(RuntimeError, "sink down")

      expect {
        described_class.record!(phase: "agent_process_spawn", chat_session_id: 1, chat_message_id: 1)
      }.not_to raise_error
    end

    it "does not leak secrets: only identifiers and short metadata values are stored" do
      event = described_class.record!(
        phase: "agent_process_spawn",
        provider: "claude",
        chat_session_id: 1,
        chat_message_id: 1,
        metadata: { oauth_token: "sk-should-not-be-passed-but-would-be-truncated" * 20 }
      )

      expect(event.keys).not_to include("prompt", "response", "token")
      expect(event["metadata"]["oauth_token"].bytesize).to be <= 500
    end
  end

  describe ".stalled_phase_for" do
    it "returns nil once every canonical phase has been observed" do
      described_class::PHASES.each do |phase|
        described_class.record!(phase: phase, server_name: "syrus-chat-sidecar", chat_session_id: 5, chat_message_id: 9)
      end

      expect(described_class.stalled_phase_for(chat_session_id: 5, chat_message_id: 9)).to be_nil
    end

    it "identifies the earliest phase the lifecycle never reached (unambiguous timeout attribution)" do
      described_class.record!(phase: "agent_process_spawn", chat_session_id: 5, chat_message_id: 9)
      described_class.record!(phase: "sidecar_process_spawn", server_name: "syrus-chat-sidecar", chat_session_id: 5, chat_message_id: 9)
      # sidecar_application_boot never recorded -- Rails boot in the sidecar hung.

      expect(described_class.stalled_phase_for(chat_session_id: 5, chat_message_id: 9)).to eq("sidecar_application_boot")
    end

    it "scopes to one server without losing turn-scoped (server-less) phases" do
      described_class.record!(phase: "agent_process_spawn", chat_session_id: 5, chat_message_id: 9)
      described_class::PHASES.select { |p| described_class::SOURCE_BY_PHASE[p] == "sidecar" }.each do |phase|
        described_class.record!(phase: phase, server_name: "syrus-chat-sidecar", chat_session_id: 5, chat_message_id: 9)
      end

      expect(described_class.stalled_phase_for(chat_session_id: 5, chat_message_id: 9, server_name: "syrus-chat-sidecar"))
        .to eq("required_server_ready")
    end
  end

  describe ".log_stalled_phase!" do
    it "logs and returns the stalled phase" do
      described_class.record!(phase: "agent_process_spawn", chat_session_id: 5, chat_message_id: 9)

      expect(Rails.logger).to receive(:warn).with(/stalled .*phase=sidecar_process_spawn/)
      expect(described_class.log_stalled_phase!(chat_session_id: 5, chat_message_id: 9)).to eq("sidecar_process_spawn")
    end

    it "logs nothing when the lifecycle completed" do
      described_class::PHASES.each { |phase| described_class.record!(phase: phase, chat_session_id: 5, chat_message_id: 9) }

      expect(Rails.logger).not_to receive(:warn)
      expect(described_class.log_stalled_phase!(chat_session_id: 5, chat_message_id: 9)).to be_nil
    end
  end
end
