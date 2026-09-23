require "rails_helper"

# These specs cover Mcp::Sidecar's McpStartupTiming wiring: the two phases
# the sidecar process can time directly (its own OS process starting, Rails
# finishing boot) plus the two MCP protocol milestones only visible from
# inside this process (the initialize handshake and the tools/list
# response). Frames are fed straight through MCP::Server#handle_json, the
# same technique spec/services/syrus_mcp/sidecar_spec.rb and
# spec/services/syrus_chat_mcp/sidecar_spec.rb use to avoid a real stdio
# subprocess.
RSpec.describe Mcp::Sidecar do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }
  let(:message) { chat_session.messages.create!(role: "user", content: { text: "hi" }) }

  def jsonrpc(server, method, id: 1, params: {})
    raw = server.handle_json({ jsonrpc: "2.0", id: id, method: method, params: params }.to_json)
    raw && JSON.parse(raw, symbolize_names: true)
  end

  def recorded_phases(chat_session_id: chat_session.id, chat_message_id: message.id)
    Observability::EventSink.flush!(kinds: [ :mcp_startup_phase ])
    McpStartupPhaseEvent.where(chat_session_id: chat_session_id, chat_message_id: chat_message_id)
  end

  def chat_sidecar
    described_class.new(
      server_name: described_class::CHAT_ESSENTIAL_SERVER,
      tools: -> { [] },
      server_context: -> { { chat_session: chat_session } },
      tier: :essential,
      chat_session_id: chat_session.id,
      chat_message_id: message.id,
      process_spawned_at: 2.seconds.ago,
      application_booted_at: 1.second.ago
    )
  end

  describe "#record_startup_timing_phases!" do
    it "records the process-spawn and application-boot phases at the timestamps it was given" do
      sidecar = chat_sidecar

      sidecar.send(:record_startup_timing_phases!)

      spawn_event = recorded_phases.find_by(phase: "sidecar_process_spawn")
      boot_event = recorded_phases.find_by(phase: "sidecar_application_boot")
      expect(spawn_event).to have_attributes(server_name: described_class::CHAT_ESSENTIAL_SERVER, tier: "essential")
      expect(boot_event).to be_present
      expect(boot_event.occurred_at).to be > spawn_event.occurred_at
    end

    it "is a no-op for the workflow sidecar, which never supplies a spawn timestamp" do
      run = Factories.job.initial_run
      sidecar = described_class.workflow(run_id: run.id)

      sidecar.send(:record_startup_timing_phases!)

      expect(McpStartupPhaseEvent.count).to eq(0)
    end
  end

  describe "MCP protocol instrumentation (around_request)" do
    after { MCP.configuration.around_request = nil }

    it "records initialize_request_received/initialize_response_sent around the initialize handshake" do
      sidecar = chat_sidecar
      server = sidecar.build_server
      sidecar.send(:record_startup_timing_phases!)

      jsonrpc(server, "initialize", params: { protocolVersion: "2025-06-18", clientInfo: { name: "test", version: "1" }, capabilities: {} })

      phases = recorded_phases
      request_received = phases.find_by(phase: "initialize_request_received")
      response_sent = phases.find_by(phase: "initialize_response_sent")
      expect(request_received).to be_present
      expect(response_sent).to be_present
      expect(response_sent.occurred_at).to be >= request_received.occurred_at
    end

    it "records tool_inventory_received around the tools/list response" do
      sidecar = chat_sidecar
      server = sidecar.build_server
      sidecar.send(:record_startup_timing_phases!)
      jsonrpc(server, "initialize", id: 0)

      jsonrpc(server, "tools/list")

      expect(recorded_phases.pluck(:phase)).to include("tool_inventory_received")
    end

    it "does not record a phase for unrelated methods like ping" do
      sidecar = chat_sidecar
      server = sidecar.build_server
      sidecar.send(:record_startup_timing_phases!)
      jsonrpc(server, "initialize", id: 0)

      jsonrpc(server, "ping")

      # Only the process-spawn/boot phases plus the initialize handshake
      # phases exist -- nothing recorded for the unrelated ping call.
      expect(recorded_phases.pluck(:phase).uniq).to match_array(
        %w[sidecar_process_spawn sidecar_application_boot initialize_request_received initialize_response_sent]
      )
    end
  end
end
