require "rails_helper"

RSpec.describe SyrusBrowser::DropTool do
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

  it "has the expected tool name" do
    expect(described_class.tool_name).to eq("browser_drop")
  end

  it "requires target" do
    expect(described_class.input_schema_value.to_h[:required]).to eq([ "target" ])
  end

  it "forwards element, target, and paths to the upstream browser_drop tool" do
    allow(session).to receive(:call_tool).and_return({ "result" => { "content" => [] } })

    described_class.call(
      element: "Bug report drop zone", target: "e9", paths: [ "/tmp/screenshot.png" ], server_context: ctx
    )

    expect(session).to have_received(:call_tool).with(
      name: "browser_drop",
      arguments: { "element" => "Bug report drop zone", "target" => "e9", "paths" => [ "/tmp/screenshot.png" ] }
    )
  end

  it "forwards data instead of paths when dropping MIME-typed data" do
    allow(session).to receive(:call_tool).and_return({ "result" => { "content" => [] } })

    described_class.call(target: "e9", data: { "text/plain" => "hello" }, server_context: ctx)

    expect(session).to have_received(:call_tool).with(
      name: "browser_drop", arguments: { "target" => "e9", "data" => { "text/plain" => "hello" } }
    )
  end

  it "accepts legacy ref as a target alias" do
    allow(session).to receive(:call_tool).and_return({ "result" => { "content" => [] } })

    described_class.call(ref: "e9", paths: [ "/tmp/screenshot.png" ], server_context: ctx)

    expect(session).to have_received(:call_tool).with(
      name: "browser_drop", arguments: { "target" => "e9", "paths" => [ "/tmp/screenshot.png" ] }
    )
  end

  it "rejects missing snapshot targets before calling the upstream browser" do
    response = described_class.call(paths: [ "/tmp/screenshot.png" ], server_context: ctx)

    expect(response).to be_error
    expect(response.content.first[:text]).to include("requires target")
    expect(session).not_to have_received(:call_tool)
  end

  it "rejects a call with neither paths nor data before calling the upstream browser" do
    response = described_class.call(target: "e9", server_context: ctx)

    expect(response).to be_error
    expect(response.content.first[:text]).to include("requires at least one of paths or data")
    expect(session).not_to have_received(:call_tool)
  end
end
