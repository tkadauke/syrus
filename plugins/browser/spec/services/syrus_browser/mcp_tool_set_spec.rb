require "rails_helper"

RSpec.describe SyrusBrowser::McpToolSet do
  let(:tool_set) { described_class.new }
  let(:run) { instance_double(Run, id: 42) }
  let(:session) { instance_double(SyrusBrowser::Session, call_tool: nil, close: nil) }
  let(:ctx) { { run_id: 42 } }

  before do
    allow(Mcp::Tools).to receive(:run_from_context).with(ctx).and_return(run)
    SyrusBrowser::SessionRegistry.session_factory = ->(_run_id) { session }
  end

  after do
    SyrusBrowser::SessionRegistry.reset!
  end

  describe ".tool_definitions" do
    subject(:defs) { described_class.tool_definitions }

    it "exposes seven granular browser tools" do
      names = defs.map { |d| d[:name] }
      expect(names).to contain_exactly(
        "browser_navigate", "browser_click", "browser_fill", "browser_snapshot",
        "browser_screenshot", "browser_wait_for", "browser_close"
      )
    end

    it "every definition has a non-empty description" do
      defs.each { |d| expect(d[:description]).to be_present }
    end

    it "browser_navigate requires url" do
      navigate = defs.find { |d| d[:name] == "browser_navigate" }
      expect(navigate[:input_schema][:required]).to include("url")
    end

    it "browser_click and browser_fill require element and ref" do
      click = defs.find { |d| d[:name] == "browser_click" }
      fill = defs.find { |d| d[:name] == "browser_fill" }
      expect(click[:input_schema][:required]).to include("element", "ref")
      expect(fill[:input_schema][:required]).to include("element", "ref", "text")
    end
  end

  describe ".available_for?" do
    it "returns true for any repository" do
      expect(described_class.available_for?(double("repository"))).to be true
    end
  end

  describe "#handle browser_navigate" do
    it "blocks navigation to a non-loopback URL without touching the browser session" do
      response = tool_set.handle("browser_navigate", { "url" => "http://evil.example.com" }, ctx)

      expect(response).to be_error
      expect(response.content.first[:text]).to match(/blocked/i)
      expect(session).not_to have_received(:call_tool)
    end

    it "returns an error when url is missing" do
      response = tool_set.handle("browser_navigate", {}, ctx)

      expect(response).to be_error
      expect(response.content.first[:text]).to match(/url is required/)
    end

    it "forwards a loopback navigate to the upstream browser_navigate tool" do
      allow(session).to receive(:call_tool).and_return(
        { "result" => { "content" => [ { "type" => "text", "text" => "navigated" } ] } }
      )

      response = tool_set.handle("browser_navigate", { "url" => "http://127.0.0.1:3001/dashboard" }, ctx)

      expect(session).to have_received(:call_tool).with(
        name: "browser_navigate", arguments: { "url" => "http://127.0.0.1:3001/dashboard" }
      )
      expect(response).not_to be_error
      expect(response.content.first[:text]).to eq("navigated")
    end

    it "allows navigation to localhost" do
      allow(session).to receive(:call_tool).and_return({ "result" => { "content" => [] } })

      tool_set.handle("browser_navigate", { "url" => "http://localhost:3001" }, ctx)

      expect(session).to have_received(:call_tool).with(
        name: "browser_navigate", arguments: { "url" => "http://localhost:3001" }
      )
    end
  end

  describe "#handle browser_snapshot" do
    it "forwards to the upstream browser_snapshot tool with no arguments" do
      allow(session).to receive(:call_tool).and_return({ "result" => { "content" => [] } })

      tool_set.handle("browser_snapshot", {}, ctx)

      expect(session).to have_received(:call_tool).with(name: "browser_snapshot", arguments: {})
    end
  end

  describe "#handle browser_click" do
    it "forwards element and ref to the upstream browser_click tool" do
      allow(session).to receive(:call_tool).and_return({ "result" => { "content" => [] } })

      tool_set.handle("browser_click", { "element" => "Submit button", "ref" => "e3" }, ctx)

      expect(session).to have_received(:call_tool).with(
        name: "browser_click", arguments: { "element" => "Submit button", "ref" => "e3" }
      )
    end
  end

  describe "#handle browser_fill" do
    it "maps to the upstream browser_type tool" do
      allow(session).to receive(:call_tool).and_return({ "result" => { "content" => [] } })

      tool_set.handle("browser_fill", { "element" => "Email field", "ref" => "e1", "text" => "a@b.com" }, ctx)

      expect(session).to have_received(:call_tool).with(
        name: "browser_type",
        arguments: { "element" => "Email field", "ref" => "e1", "text" => "a@b.com" }
      )
    end
  end

  describe "#handle browser_screenshot" do
    it "maps to the upstream browser_take_screenshot tool and returns image content" do
      allow(session).to receive(:call_tool).and_return(
        { "result" => { "content" => [ { "type" => "image", "data" => "base64data", "mimeType" => "image/png" } ] } }
      )

      response = tool_set.handle("browser_screenshot", { "ref" => "e2" }, ctx)

      expect(session).to have_received(:call_tool).with(
        name: "browser_take_screenshot", arguments: { "ref" => "e2" }
      )
      expect(response.content.first[:type]).to eq("image")
      expect(response.content.first[:data]).to eq("base64data")
    end
  end

  describe "#handle browser_wait_for" do
    it "translates text_gone into the upstream camelCase textGone argument" do
      allow(session).to receive(:call_tool).and_return({ "result" => { "content" => [] } })

      tool_set.handle("browser_wait_for", { "text_gone" => "Loading…" }, ctx)

      expect(session).to have_received(:call_tool).with(
        name: "browser_wait_for", arguments: { "textGone" => "Loading…" }
      )
    end

    it "forwards text and time when given" do
      allow(session).to receive(:call_tool).and_return({ "result" => { "content" => [] } })

      tool_set.handle("browser_wait_for", { "text" => "Done", "time" => 5 }, ctx)

      expect(session).to have_received(:call_tool).with(
        name: "browser_wait_for", arguments: { "text" => "Done", "time" => 5 }
      )
    end
  end

  describe "#handle browser_close" do
    it "kills the session for the run without calling the upstream server" do
      allow(SyrusBrowser::SessionRegistry).to receive(:kill)

      response = tool_set.handle("browser_close", {}, ctx)

      expect(SyrusBrowser::SessionRegistry).to have_received(:kill).with(42)
      expect(session).not_to have_received(:call_tool)
      expect(response).not_to be_error
    end
  end

  describe "#handle unknown tool" do
    it "returns an error response" do
      response = tool_set.handle("no_such_tool", {}, ctx)
      expect(response).to be_error
    end
  end

  describe "error handling" do
    it "returns an error response when the upstream server raises" do
      allow(session).to receive(:call_tool).and_raise(MCP::Client::ServerError.new("boom", code: -1))

      response = tool_set.handle("browser_snapshot", {}, ctx)

      expect(response).to be_error
      expect(response.content.first[:text]).to match(/boom/)
    end

    it "returns an error response for any other unexpected failure" do
      allow(session).to receive(:call_tool).and_raise(StandardError.new("kaboom"))

      response = tool_set.handle("browser_snapshot", {}, ctx)

      expect(response).to be_error
      expect(response.content.first[:text]).to match(/kaboom/)
    end
  end
end
