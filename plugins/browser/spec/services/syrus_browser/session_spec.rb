require "rails_helper"

RSpec.describe SyrusBrowser::Session do
  let(:transport) { instance_double(MCP::Client::Stdio, close: nil) }
  let(:client) { instance_double(MCP::Client, connect: { "protocolVersion" => "2025-11-25" }, call_tool: { "result" => { "content" => [] } }) }

  before do
    allow(MCP::Client::Stdio).to receive(:new).and_return(transport)
    allow(MCP::Client).to receive(:new).with(transport: transport).and_return(client)
  end

  describe "#initialize" do
    it "spawns the stdio transport with the default @playwright/mcp command" do
      described_class.new(1)

      expect(MCP::Client::Stdio).to have_received(:new).with(
        command: "npx", args: %w[--yes @playwright/mcp --headless --isolated], env: nil
      )
    end

    it "allows overriding the command, args, and env" do
      described_class.new(1, command: "playwright-mcp", args: %w[--headless], env: { "FOO" => "bar" })

      expect(MCP::Client::Stdio).to have_received(:new).with(
        command: "playwright-mcp", args: %w[--headless], env: { "FOO" => "bar" }
      )
    end
  end

  describe "#call_tool" do
    it "connects once and then forwards the call to the underlying MCP client" do
      session = described_class.new(1)

      session.call_tool(name: "browser_snapshot", arguments: {})
      session.call_tool(name: "browser_click", arguments: { "ref" => "e1" })

      expect(client).to have_received(:connect).once
      expect(client).to have_received(:call_tool).with(name: "browser_snapshot", arguments: {})
      expect(client).to have_received(:call_tool).with(name: "browser_click", arguments: { "ref" => "e1" })
    end

    it "returns the underlying client's response" do
      session = described_class.new(1)
      allow(client).to receive(:call_tool).and_return({ "result" => { "content" => [ { "type" => "text", "text" => "ok" } ] } })

      response = session.call_tool(name: "browser_snapshot", arguments: {})

      expect(response.dig("result", "content", 0, "text")).to eq("ok")
    end
  end

  describe "#close" do
    it "closes the underlying transport" do
      session = described_class.new(1)

      session.close

      expect(transport).to have_received(:close)
    end

    it "swallows errors from a transport that is already closed" do
      allow(transport).to receive(:close).and_raise(IOError, "closed stream")
      session = described_class.new(1)

      expect { session.close }.not_to raise_error
    end
  end
end
