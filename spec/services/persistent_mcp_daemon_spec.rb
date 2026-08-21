require "rails_helper"
require "rack/mock"
require "tmpdir"

RSpec.describe PersistentMcpDaemon do
  let(:data_root) { Dir.mktmpdir("syrus-persistent-mcp-daemon") }
  let(:daemon) { described_class.new }

  before { ENV["SYRUS_DATA_ROOT"] = data_root }

  after do
    ENV.delete("SYRUS_DATA_ROOT")
    FileUtils.rm_rf(data_root)
  end

  def set_feature(enabled)
    Feature.find_or_create_by!(slug: "persistent_mcp_sidecar") do |feature|
      feature.category = "Labs"
      feature.name = "Persistent MCP sidecar"
    end.update!(enabled: enabled)
    Feature.clear_enabled_cache!("persistent_mcp_sidecar")
  end

  def call(path, method: "GET", body: nil)
    env = Rack::MockRequest.env_for(
      path,
      method: method,
      input: body,
      "CONTENT_TYPE" => "application/json",
      "HTTP_ACCEPT" => "application/json, text/event-stream"
    )
    daemon.call(env)
  end

  def json_body(response)
    JSON.parse(response[2].first)
  end

  describe "#call" do
    describe "GET /healthz" do
      it "reports boot success, the enumerated tool set, and a successful no-op ping" do
        response = call("/healthz")

        expect(response[0]).to eq(200)
        body = json_body(response)
        expect(body["status"]).to eq("ok")
        expect(body["tools"]).to eq([ "daemon_ping" ])
        expect(body["ping_ok"]).to be true
        expect(body["identity"]).to include(
          "worker_id" => WorkerStorageIdentity.key(data_root: data_root),
          "hostname" => SyrusVersion.hostname,
          "pid" => Process.pid
        )
      end

      it "returns 503 when the no-op ping round trip does not succeed" do
        allow(daemon.mcp_server).to receive(:handle_json).and_wrap_original do |original, json|
          parsed = JSON.parse(json)
          if parsed["method"] == "ping"
            { jsonrpc: "2.0", id: parsed["id"], result: { unexpected: true } }.to_json
          else
            original.call(json)
          end
        end

        response = call("/healthz")

        expect(response[0]).to eq(503)
        expect(json_body(response)["status"]).to eq("error")
      end
    end

    describe "MCP transport at /mcp" do
      it "initializes and enumerates the daemon_ping tool over the real JSON-RPC transport" do
        init_response = call(
          "/mcp",
          method: "POST",
          body: {
            jsonrpc: "2.0",
            id: 1,
            method: "initialize",
            params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "spec", version: "1.0" } }
          }.to_json
        )

        expect(init_response[0]).to eq(200)
        init_body = json_body(init_response)
        expect(init_body.dig("result", "serverInfo", "name")).to eq("syrus-persistent-mcp-daemon")

        list_response = call(
          "/mcp",
          method: "POST",
          body: { jsonrpc: "2.0", id: 2, method: "tools/list" }.to_json
        )

        expect(list_response[0]).to eq(200)
        tool_names = json_body(list_response).dig("result", "tools").map { |tool| tool["name"] }
        expect(tool_names).to eq([ "daemon_ping" ])
      end
    end

    it "returns 404 for unknown paths" do
      response = call("/nope")

      expect(response[0]).to eq(404)
    end
  end

  describe "#identity" do
    it "reuses WorkerStorageIdentity's stable per-data-root id" do
      identity = daemon.identity

      expect(identity[:worker_id]).to eq(WorkerStorageIdentity.key(data_root: data_root))
      expect(identity[:hostname]).to eq(SyrusVersion.hostname)
      expect(identity[:role]).to eq(SyrusVersion.role)
      expect(identity[:pid]).to eq(Process.pid)
    end

    it "is stable across daemon instances on the same data root" do
      expect(described_class.new.identity[:worker_id]).to eq(described_class.new.identity[:worker_id])
    end
  end

  describe "#start" do
    it "refuses to boot while the persistent_mcp_sidecar feature is disabled" do
      set_feature(false)
      expect(Puma::Server).not_to receive(:new)

      expect { daemon.start }.to raise_error(/persistent_mcp_sidecar feature is disabled/)
    end

    it "boots a Puma::Server bound to the configured host/port when the feature is enabled" do
      set_feature(true)
      fake_thread = instance_double(Thread, join: nil)
      fake_server = instance_double(Puma::Server, add_tcp_listener: nil, run: fake_thread, stop: nil)
      expect(Puma::Server).to receive(:new).and_return(fake_server)

      result = daemon.start

      expect(result).to eq(daemon)
      expect(fake_server).to have_received(:add_tcp_listener).with(described_class::DEFAULT_HOST, described_class.port)
      expect(fake_server).to have_received(:run).with(true, thread_name: "persistent-mcp-daemon")

      daemon.join
      expect(fake_thread).to have_received(:join)

      daemon.stop
      expect(fake_server).to have_received(:stop).with(true)
    end

    it "refuses to start a second time on the same instance" do
      set_feature(true)
      fake_server = instance_double(Puma::Server, add_tcp_listener: nil, run: instance_double(Thread, join: nil), stop: nil)
      allow(Puma::Server).to receive(:new).and_return(fake_server)

      daemon.start

      expect { daemon.start }.to raise_error(/already started/)
    end
  end
end
