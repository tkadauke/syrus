require "rails_helper"

RSpec.describe SyrusBrowser::HoverTool do
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
    expect(described_class.tool_name).to eq("browser_hover")
  end

  it "requires target" do
    expect(described_class.input_schema_value.to_h[:required]).to eq([ "target" ])
  end

  it "forwards element and target to the upstream browser_hover tool" do
    allow(session).to receive(:call_tool).and_return({ "result" => { "content" => [] } })

    described_class.call(element: "Slug link", target: "e5", server_context: ctx)

    expect(session).to have_received(:call_tool).with(
      name: "browser_hover", arguments: { "element" => "Slug link", "target" => "e5" }
    )
  end

  it "accepts legacy ref as a target alias" do
    allow(session).to receive(:call_tool).and_return({ "result" => { "content" => [] } })

    described_class.call(element: "Slug link", ref: "e5", server_context: ctx)

    expect(session).to have_received(:call_tool).with(
      name: "browser_hover", arguments: { "element" => "Slug link", "target" => "e5" }
    )
  end

  it "rejects missing snapshot targets before calling the upstream browser" do
    response = described_class.call(element: "Slug link", server_context: ctx)

    expect(response).to be_error
    expect(response.content.first[:text]).to include("requires target")
    expect(response.content.first[:text]).to include("browser_snapshot")
    expect(session).not_to have_received(:call_tool)
  end
end
