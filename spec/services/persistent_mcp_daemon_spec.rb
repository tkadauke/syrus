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
        expect(body["tools"]).to include("daemon_ping", "daemon_invocation_context", "list_jobs", "read_workflow")
        expect(body["tools"].size).to eq(McpToolRegistry.tools(surface: :chat).uniq.size + 2)
        expect(body["ping_ok"]).to be true
        expect(body["identity"]).to include(
          "worker_id" => WorkerStorageIdentity.key(data_root: data_root),
          "hostname" => SyrusVersion.hostname,
          "pid" => Process.pid
        )
      end

      it "advertises chat_tools but not workflow_tools until the real workflow tool set is wired in" do
        response = call("/healthz")

        expect(json_body(response)["capabilities"]).to eq([ "chat_tools" ])
        expect(described_class::CAPABILITIES).to eq([ "chat_tools" ])
        expect(described_class::CAPABILITIES).not_to include(described_class::WORKFLOW_TOOLS_CAPABILITY)
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
        expect(tool_names).to include("daemon_ping", "daemon_invocation_context", "list_jobs", "admin_overview")
      end
    end

    describe "chat tool dispatch over /mcp (PersistentMcpDaemon::ChatToolDispatch)" do
      let!(:bootstrap_admin) { Factories.user(admin: true) }
      let(:user) { Factories.user }
      let(:repository) { Factories.repository(user: user) }
      let(:chat) { ChatSession.create!(user: user, repository: repository) }
      let(:worker_id) { WorkerStorageIdentity.key(data_root: data_root) }

      def call_tool(name, token:, arguments: {})
        call(
          "/mcp",
          method: "POST",
          body: {
            jsonrpc: "2.0", id: 1, method: "tools/call",
            params: { name: name, arguments: arguments }
          }.to_json,
          headers: { "HTTP_X_SYRUS_INVOCATION_CONTEXT" => token }
        )
      end

      def call(path, method: "GET", body: nil, headers: {})
        env = Rack::MockRequest.env_for(
          path, method: method, input: body,
          "CONTENT_TYPE" => "application/json",
          "HTTP_ACCEPT" => "application/json, text/event-stream",
          **headers
        )
        daemon.call(env)
      end

      it "dispatches an ordinary essential-tier chat tool for a ChatMcpTransportSelector-selected turn" do
        token = McpInvocationContext.issue_for_chat(chat, worker_id: worker_id, tier: "essential")

        response = call_tool("list_jobs", token: token)

        expect(response[0]).to eq(200)
        result = json_body(response)["result"]
        expect(result["isError"]).to be_falsey
        payload = JSON.parse(result.dig("content", 0, "text"))
        expect(payload["jobs"]).to eq([])
      end

      it "denies an admin-only tool for a non-admin chat session" do
        token = McpInvocationContext.issue_for_chat(chat, worker_id: worker_id, tier: "essential")

        response = call_tool("admin_overview", token: token)

        expect(response[0]).to eq(200)
        result = json_body(response)["result"]
        expect(result["isError"]).to be true
        expect(JSON.parse(result.dig("content", 0, "text"))["error"]).to eq("not_authorized")
      end

      it "dispatches an admin-only chat tool for an admin chat session" do
        admin_chat = ChatSession.create!(user: bootstrap_admin, repository: Factories.repository(user: bootstrap_admin))
        token = McpInvocationContext.issue_for_chat(admin_chat, worker_id: worker_id, tier: "essential")

        response = call_tool("admin_overview", token: token)

        expect(response[0]).to eq(200)
        result = json_body(response)["result"]
        expect(result["isError"]).to be_falsey
        expect(JSON.parse(result.dig("content", 0, "text"))).to have_key("total_users")
      end

      it "denies a deferred-tier tool called through the essential-tier token" do
        token = McpInvocationContext.issue_for_chat(chat, worker_id: worker_id, tier: "essential")

        response = call_tool("read_workflow", token: token, arguments: { workflow_id: 1 })

        result = json_body(response)["result"]
        expect(result["isError"]).to be true
        expect(JSON.parse(result.dig("content", 0, "text"))["error"]).to eq("not_authorized")
      end

      it "returns an Unauthorized tool error for an expired invocation token" do
        token = McpInvocationContext.issue_for_chat(chat, worker_id: worker_id, expires_in: -1.minute)

        response = call_tool("list_jobs", token: token)

        result = json_body(response)["result"]
        expect(result["isError"]).to be true
        expect(result.dig("content", 0, "text")).to match(/Unauthorized: invocation context Expired/)
      end

      describe "MCP usage recording at the dispatch boundary (EPIC-250, McpToolUsageRecorder)" do
        it "records a completed usage row tagged sidecar_mode=persistent for a successful dispatch" do
          token = McpInvocationContext.issue_for_chat(chat, worker_id: worker_id, tier: "essential")

          expect { call_tool("list_jobs", token: token) }.to change(McpToolUsage, :count).by(1)

          usage = McpToolUsage.sole
          expect(usage).to have_attributes(
            surface: "chat",
            normalized_tool_name: "list_jobs",
            status: "completed",
            error: false,
            sidecar_mode: "persistent",
            daemon_worker_id: worker_id,
            chat_session_id: chat.id
          )
        end

        it "records a failed usage row for a not_authorized dispatch" do
          token = McpInvocationContext.issue_for_chat(chat, worker_id: worker_id, tier: "essential")

          expect { call_tool("admin_overview", token: token) }.to change(McpToolUsage, :count).by(1)

          usage = McpToolUsage.sole
          expect(usage).to have_attributes(
            surface: "chat",
            normalized_tool_name: "admin_overview",
            status: "failed",
            error: true,
            sidecar_mode: "persistent",
            chat_session_id: chat.id
          )
          expect(usage.error_message_summary).to match(/not_authorized/)
        end

        it "records a failed usage row -- without a chat_session -- for a rejection before the invocation context resolves" do
          token = McpInvocationContext.issue_for_chat(chat, worker_id: worker_id, expires_in: -1.minute)

          expect { call_tool("list_jobs", token: token) }.to change(McpToolUsage, :count).by(1)

          usage = McpToolUsage.sole
          expect(usage).to have_attributes(
            surface: "chat",
            normalized_tool_name: "list_jobs",
            status: "failed",
            error: true,
            sidecar_mode: "persistent",
            chat_session_id: nil,
            error_class: "McpInvocationContext::Expired"
          )
        end
      end
    end

    it "returns 404 for unknown paths" do
      response = call("/nope")

      expect(response[0]).to eq(404)
    end

    describe "#inject_invocation_context (private -- bridges the header into params._meta)" do
      def build_env(body:, headers: {})
        Rack::MockRequest.env_for(
          "/mcp",
          method: "POST",
          input: body,
          "CONTENT_TYPE" => "application/json",
          "HTTP_ACCEPT" => "application/json, text/event-stream",
          **headers
        )
      end

      def injected_body(env)
        result_env = daemon.send(:inject_invocation_context, env)
        JSON.parse(result_env["rack.input"].read, symbolize_names: true)
      end

      it "merges the header token into params._meta under INVOCATION_CONTEXT_META_KEY" do
        body = { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "daemon_ping" } }.to_json
        env = build_env(body: body, headers: { "HTTP_X_SYRUS_INVOCATION_CONTEXT" => "some-token" })

        parsed = injected_body(env)

        expect(parsed.dig(:params, :_meta, described_class::INVOCATION_CONTEXT_META_KEY.to_sym)).to eq("some-token")
      end

      it "preserves any _meta the request already carried" do
        body = { jsonrpc: "2.0", id: 1, method: "tools/call",
                 params: { name: "daemon_ping", _meta: { progressToken: "abc" } } }.to_json
        env = build_env(body: body, headers: { "HTTP_X_SYRUS_INVOCATION_CONTEXT" => "some-token" })

        parsed = injected_body(env)

        expect(parsed[:params][:_meta]).to include(
          progressToken: "abc",
          described_class::INVOCATION_CONTEXT_META_KEY.to_sym => "some-token"
        )
      end

      it "returns the env unchanged when no header is present" do
        body = { jsonrpc: "2.0", id: 1, method: "tools/list" }.to_json
        env = build_env(body: body)

        result_env = daemon.send(:inject_invocation_context, env)

        expect(result_env).to equal(env)
      end

      it "returns the env unchanged (without raising) for a malformed body even when the header is present" do
        env = build_env(body: "not json", headers: { "HTTP_X_SYRUS_INVOCATION_CONTEXT" => "some-token" })

        result_env = daemon.send(:inject_invocation_context, env)

        expect(result_env).to equal(env)
      end
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
