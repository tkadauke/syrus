require "rails_helper"

RSpec.describe SyrusBrowser::Session do
  let(:transport) { instance_double(MCP::Client::Stdio, close: nil) }
  let(:client) { instance_double(MCP::Client, connect: { "protocolVersion" => "2025-11-25" }, call_tool: { "result" => { "content" => [] } }) }

  before do
    allow(MCP::Client::Stdio).to receive(:new).and_return(transport)
    allow(MCP::Client).to receive(:new).with(transport: transport).and_return(client)
  end

  around do |example|
    original = ENV["SYRUS_BROWSER_EXECUTABLE_PATH"]
    ENV.delete("SYRUS_BROWSER_EXECUTABLE_PATH")
    example.run
  ensure
    ENV["SYRUS_BROWSER_EXECUTABLE_PATH"] = original
  end

  describe "#initialize" do
    it "spawns the stdio transport with the default @playwright/mcp command" do
      described_class.new(1)

      expect(MCP::Client::Stdio).to have_received(:new).with(
        command: "playwright-mcp",
        args: %w[--headless --isolated --block-service-workers --executable-path /opt/syrus-browser/chromium],
        env: nil
      )
    end

    it "allows overriding the browser executable path through the environment" do
      ENV["SYRUS_BROWSER_EXECUTABLE_PATH"] = "/custom/chromium"

      described_class.new(1)

      expect(MCP::Client::Stdio).to have_received(:new).with(
        command: "playwright-mcp",
        args: %w[--headless --isolated --block-service-workers --executable-path /custom/chromium],
        env: nil
      )
    end

    it "allows overriding the command, args, and env" do
      described_class.new(1, command: "playwright-mcp", args: %w[--headless], env: { "FOO" => "bar" })

      expect(MCP::Client::Stdio).to have_received(:new).with(
        command: "playwright-mcp", args: %w[--headless], env: { "FOO" => "bar" }
      )
    end
  end

  describe ".spawn_stdio" do
    it "passes browser environment hints to the stdio transport" do
      described_class.spawn_stdio(1)

      expect(MCP::Client::Stdio).to have_received(:new).with(
        command: "playwright-mcp",
        args: %w[--headless --isolated --block-service-workers --executable-path /opt/syrus-browser/chromium],
        env: {
          "PLAYWRIGHT_MCP_EXECUTABLE_PATH" => "/opt/syrus-browser/chromium",
          "PLAYWRIGHT_BROWSERS_PATH" => "/opt/ms-playwright"
        }
      )
    end

    it "merges caller-provided environment values" do
      described_class.spawn_stdio(1, env: { "FOO" => "bar" })

      expect(MCP::Client::Stdio).to have_received(:new).with(
        command: "playwright-mcp",
        args: %w[--headless --isolated --block-service-workers --executable-path /opt/syrus-browser/chromium],
        env: {
          "PLAYWRIGHT_MCP_EXECUTABLE_PATH" => "/opt/syrus-browser/chromium",
          "PLAYWRIGHT_BROWSERS_PATH" => "/opt/ms-playwright",
          "FOO" => "bar"
        }
      )
    end
  end

  describe ".spawn_service" do
    let(:http_transport) { instance_double(MCP::Client::HTTP, close: nil) }

    before do
      allow(MCP::Client::HTTP).to receive(:new).and_return(http_transport)
      allow(MCP::Client).to receive(:new).with(transport: http_transport).and_return(client)
    end

    it "connects over streamable HTTP MCP at the service's /mcp endpoint" do
      described_class.spawn_service(1, endpoint: "http://browser-service:8080")

      expect(MCP::Client::HTTP).to have_received(:new).with(
        url: "http://browser-service:8080/mcp", headers: {}
      )
    end

    it "strips a trailing slash from the endpoint before appending /mcp" do
      described_class.spawn_service(1, endpoint: "http://browser-service:8080/")

      expect(MCP::Client::HTTP).to have_received(:new).with(
        url: "http://browser-service:8080/mcp", headers: {}
      )
    end

    it "forwards caller-provided headers" do
      described_class.spawn_service(1, endpoint: "http://browser-service:8080", headers: { "Authorization" => "Bearer x" })

      expect(MCP::Client::HTTP).to have_received(:new).with(
        url: "http://browser-service:8080/mcp", headers: { "Authorization" => "Bearer x" }
      )
    end

    it "drives the same MCP::Client#call_tool contract as the stdio transport" do
      session = described_class.spawn_service(1, endpoint: "http://browser-service:8080")

      session.call_tool(name: "browser_snapshot", arguments: {})

      expect(client).to have_received(:connect)
      expect(client).to have_received(:call_tool).with(name: "browser_snapshot", arguments: {})
    end
  end

  describe ".spawn" do
    context "when the Browser Plugin Runtime service is available" do
      before do
        allow(SyrusBrowser::Configuration).to receive(:endpoint).and_return("http://browser-service:8080")
        allow(described_class).to receive(:spawn_service).and_call_original
        http_transport = instance_double(MCP::Client::HTTP, close: nil)
        allow(MCP::Client::HTTP).to receive(:new).and_return(http_transport)
        allow(MCP::Client).to receive(:new).with(transport: http_transport).and_return(client)
      end

      it "connects to the service instead of spawning a subprocess" do
        described_class.spawn(1)

        expect(described_class).to have_received(:spawn_service).with(1, endpoint: "http://browser-service:8080")
        expect(MCP::Client::Stdio).not_to have_received(:new)
      end
    end

    context "when the Browser Plugin Runtime service is unavailable" do
      before do
        allow(SyrusBrowser::Configuration).to receive(:endpoint).and_return(nil)
      end

      it "falls back to spawning the stdio subprocess" do
        described_class.spawn(1)

        expect(MCP::Client::Stdio).to have_received(:new).with(
          command: "playwright-mcp",
          args: %w[--headless --isolated --block-service-workers --executable-path /opt/syrus-browser/chromium],
          env: {
            "PLAYWRIGHT_MCP_EXECUTABLE_PATH" => "/opt/syrus-browser/chromium",
            "PLAYWRIGHT_BROWSERS_PATH" => "/opt/ms-playwright"
          }
        )
      end
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

    it "clears browser state and reloads after the first successful navigation" do
      session = described_class.new(1)

      session.call_tool(name: "browser_navigate", arguments: { "url" => "http://localhost:3001/dashboard" })

      expect(client).to have_received(:call_tool).with(
        name: "browser_navigate",
        arguments: { "url" => "http://localhost:3001/dashboard" }
      ).twice
      expect(client).to have_received(:call_tool).with(
        name: "browser_evaluate",
        arguments: { "function" => described_class::CLEAR_BROWSER_STATE_SCRIPT }
      ).once
    end

    it "clears browser state only once per session" do
      session = described_class.new(1)

      session.call_tool(name: "browser_navigate", arguments: { "url" => "http://localhost:3001/dashboard" })
      session.call_tool(name: "browser_navigate", arguments: { "url" => "http://localhost:3001/jobs" })

      expect(client).to have_received(:call_tool).with(
        name: "browser_evaluate",
        arguments: { "function" => described_class::CLEAR_BROWSER_STATE_SCRIPT }
      ).once
      expect(client).to have_received(:call_tool).with(
        name: "browser_navigate",
        arguments: { "url" => "http://localhost:3001/jobs" }
      ).once
    end

    it "does not clear browser state after a failed navigation" do
      allow(client).to receive(:call_tool).with(
        name: "browser_navigate",
        arguments: { "url" => "http://localhost:3001/dashboard" }
      ).and_return({ "result" => { "isError" => true, "content" => [] } })

      session = described_class.new(1)
      session.call_tool(name: "browser_navigate", arguments: { "url" => "http://localhost:3001/dashboard" })

      expect(client).not_to have_received(:call_tool).with(
        name: "browser_evaluate",
        arguments: anything
      )
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
