require "rails_helper"

RSpec.describe ChatMcpTransportSelector do
  let(:host) { "127.0.0.1" }
  let(:port) { 48_106 }
  let(:health_url) { "http://#{host}:#{port}#{PersistentMcpDaemon::HEALTH_PATH}" }

  def select
    described_class.select(host: host, port: port)
  end

  def set_feature(enabled)
    Feature.find_or_create_by!(slug: "persistent_mcp_sidecar") do |feature|
      feature.category = "Labs"
      feature.name = "Persistent MCP sidecar"
    end.update!(enabled: enabled)
    Feature.clear_enabled_cache!("persistent_mcp_sidecar")
  end

  describe "#select" do
    it "returns :stdio with reason feature_disabled and makes no HTTP call when the feature is off" do
      set_feature(false)

      decision = select

      expect(decision.stdio?).to be true
      expect(decision.reason).to eq("feature_disabled")
      expect(WebMock).not_to have_requested(:get, health_url)
    end

    context "with the feature enabled" do
      before { set_feature(true) }

      it "falls back to stdio with a daemon_unreachable reason when the daemon isn't listening" do
        stub_request(:get, health_url).to_raise(Errno::ECONNREFUSED)

        decision = select

        expect(decision.stdio?).to be true
        expect(decision.reason).to match(/\Adaemon_unreachable: /)
      end

      it "falls back to stdio with a daemon_unreachable reason on timeout" do
        stub_request(:get, health_url).to_timeout

        decision = select

        expect(decision.stdio?).to be true
        expect(decision.reason).to match(/\Adaemon_unreachable: /)
      end

      it "falls back to stdio with a daemon_unhealthy reason on a non-2xx response" do
        stub_request(:get, health_url).to_return(status: 503, body: "{}")

        decision = select

        expect(decision.stdio?).to be true
        expect(decision.reason).to eq("daemon_unhealthy: HTTP 503")
      end

      it "falls back to stdio with a daemon_unhealthy reason when status isn't ok" do
        stub_request(:get, health_url).to_return(status: 200, body: { status: "error" }.to_json)

        decision = select

        expect(decision.stdio?).to be true
        expect(decision.reason).to eq('daemon_unhealthy: status="error"')
      end

      it "falls back to stdio with a daemon_unhealthy reason on an unparseable body" do
        stub_request(:get, health_url).to_return(status: 200, body: "not json")

        decision = select

        expect(decision.stdio?).to be true
        expect(decision.reason).to match(/\Adaemon_unhealthy: invalid health response/)
      end

      it "falls back to stdio with a daemon_incompatible reason when the daemon lacks chat_tools capability" do
        stub_request(:get, health_url).to_return(
          status: 200,
          body: { status: "ok", identity: { worker_id: "w1" }, capabilities: [] }.to_json
        )

        decision = select

        expect(decision.stdio?).to be true
        expect(decision.reason).to eq("daemon_incompatible: chat tool dispatch not yet supported (capabilities=none)")
      end

      it "selects the persistent transport when the daemon is healthy and advertises chat_tools" do
        stub_request(:get, health_url).to_return(
          status: 200,
          body: { status: "ok", identity: { worker_id: "w1" }, capabilities: [ "chat_tools" ] }.to_json
        )

        decision = select

        expect(decision.persistent?).to be true
        expect(decision.reason).to be_nil
        expect(decision.daemon_identity).to eq("worker_id" => "w1")
      end

      it "does not select persistent transport when the daemon only advertises workflow_tools" do
        stub_request(:get, health_url).to_return(
          status: 200,
          body: { status: "ok", identity: { worker_id: "w1" }, capabilities: [ "workflow_tools" ] }.to_json
        )

        decision = select

        expect(decision.stdio?).to be true
        expect(decision.reason).to match(/\Adaemon_incompatible: /)
      end
    end
  end
end
