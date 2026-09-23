require "rails_helper"

# End-to-end coverage for SessionRegistry's real default factory
# (`Session.spawn`) -- every other Browser spec stubs `session_factory` or
# stubs the upstream tool classes directly, so nothing proves the two call
# sites that actually reach production traffic (the visual_review workflow
# step's McpToolSet, and Coding Mode's RuntimeSessionProvider) pick the
# Browser Plugin Runtime service when one is available and fall back to the
# bundled stdio subprocess when it is not. See docs/syrus_docs/browser.md.
RSpec.describe "Browser sessions routed through the Plugin Runtime service" do
  let(:http_transport) { instance_double(MCP::Client::HTTP, close: nil) }
  let(:stdio_transport) { instance_double(MCP::Client::Stdio, close: nil) }
  let(:mcp_client) do
    instance_double(MCP::Client,
      connect: { "protocolVersion" => "2025-11-25" },
      call_tool: { "result" => { "content" => [ { "type" => "text", "text" => "ok" } ] } })
  end

  before do
    allow(MCP::Client::HTTP).to receive(:new).and_return(http_transport)
    allow(MCP::Client::Stdio).to receive(:new).and_return(stdio_transport)
    allow(MCP::Client).to receive(:new).and_return(mcp_client)
  end

  after { SyrusBrowser::SessionRegistry.reset! }

  describe "the visual_review workflow Run path (SyrusBrowser::McpToolSet)" do
    let(:run) { instance_double(Run, id: 4242) }
    let(:ctx) { { run_id: run.id } }

    before { allow(Mcp::Tools).to receive(:run_from_context).with(ctx).and_return(run) }

    it "connects to the Browser Plugin Runtime service when one is registered and healthy" do
      allow(SyrusBrowser::Configuration).to receive(:endpoint).and_return("http://browser:8080")

      response = SyrusBrowser::McpToolSet.new.handle("browser_snapshot", {}, ctx)

      expect(MCP::Client::HTTP).to have_received(:new).with(url: "http://browser:8080/mcp", headers: {})
      expect(MCP::Client::Stdio).not_to have_received(:new)
      expect(mcp_client).to have_received(:call_tool).with(name: "browser_snapshot", arguments: {})
      expect(response).not_to be_error
    end

    it "falls back to the bundled stdio subprocess when no service is available" do
      allow(SyrusBrowser::Configuration).to receive(:endpoint).and_return(nil)

      SyrusBrowser::McpToolSet.new.handle("browser_snapshot", {}, ctx)

      expect(MCP::Client::Stdio).to have_received(:new)
      expect(MCP::Client::HTTP).not_to have_received(:new)
    end

    it "reuses one service connection across multiple tool calls for the same Run" do
      allow(SyrusBrowser::Configuration).to receive(:endpoint).and_return("http://browser:8080")

      SyrusBrowser::McpToolSet.new.handle("browser_snapshot", {}, ctx)
      SyrusBrowser::McpToolSet.new.handle("browser_snapshot", {}, ctx)

      expect(MCP::Client::HTTP).to have_received(:new).once
    end
  end

  describe "Coding Mode's RuntimeSession path (SyrusBrowser::RuntimeSessionProvider)" do
    let(:user) { Factories.user }
    let(:repository) { Factories.repository(user: user) }
    let(:chat_session) { ChatSession.create!(user: user, repository: repository, mode: "coding") }
    let(:runtime_session) do
      RuntimeSession.create!(
        repository: repository, chat_session: chat_session,
        workspace_ref: "/workspace/chat-1", provider_key: "browser", display_name: "Browser", state: "running"
      )
    end
    let(:provider) { SyrusBrowser::RuntimeSessionProvider.new }

    it "connects the RuntimeSession's browser tools to the Browser Plugin Runtime service" do
      allow(SyrusBrowser::Configuration).to receive(:endpoint).and_return("http://browser:8080")

      result = provider.inspect(runtime_session.id)

      expect(MCP::Client::HTTP).to have_received(:new).with(url: "http://browser:8080/mcp", headers: {})
      expect(MCP::Client::Stdio).not_to have_received(:new)
      expect(mcp_client).to have_received(:call_tool).with(name: "browser_snapshot", arguments: {})
      expect(result[:error]).to be false
    end

    it "falls back to a per-session stdio subprocess when no service is available" do
      allow(SyrusBrowser::Configuration).to receive(:endpoint).and_return(nil)

      provider.inspect(runtime_session.id)

      expect(MCP::Client::Stdio).to have_received(:new)
      expect(MCP::Client::HTTP).not_to have_received(:new)
    end

    it "keys the RuntimeSession's service connection independently from a workflow Run's" do
      allow(SyrusBrowser::Configuration).to receive(:endpoint).and_return("http://browser:8080")
      run = instance_double(Run, id: 999)
      allow(Mcp::Tools).to receive(:run_from_context).with({ run_id: run.id }).and_return(run)

      provider.inspect(runtime_session.id)
      SyrusBrowser::McpToolSet.new.handle("browser_snapshot", {}, { run_id: run.id })

      # One HTTP connection per distinct session key (SessionRegistry keys by
      # "runtime_session:<id>" vs "run:<id>") -- not one shared browser.
      expect(MCP::Client::HTTP).to have_received(:new).twice
    end

    it "reuses the same service connection for the ChatToolSet path a coding chat calls directly" do
      allow(SyrusBrowser::Configuration).to receive(:endpoint).and_return("http://browser:8080")

      provider.inspect(runtime_session.id)
      SyrusBrowser::ChatToolSet.new.handle("browser_snapshot", {}, { chat_session: chat_session })

      expect(MCP::Client::HTTP).to have_received(:new).once
      expect(mcp_client).to have_received(:call_tool).with(name: "browser_snapshot", arguments: {}).twice
    end
  end
end
