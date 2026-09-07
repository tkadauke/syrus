require "rails_helper"

RSpec.describe SyrusBrowser::DragTool do
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
    expect(described_class.tool_name).to eq("browser_drag")
  end

  it "requires start_target and end_target" do
    expect(described_class.input_schema_value.to_h[:required]).to eq(%w[start_target end_target])
  end

  it "forwards start/end element and target to the upstream browser_drag tool" do
    allow(session).to receive(:call_tool).and_return({ "result" => { "content" => [] } })

    described_class.call(
      start_element: "List item 1", start_target: "e1",
      end_element: "List item 3", end_target: "e3",
      server_context: ctx
    )

    expect(session).to have_received(:call_tool).with(
      name: "browser_drag",
      arguments: {
        "startElement" => "List item 1", "startTarget" => "e1",
        "endElement" => "List item 3", "endTarget" => "e3"
      }
    )
  end

  it "rejects a call missing start_target without touching the upstream browser" do
    response = described_class.call(end_target: "e3", server_context: ctx)

    expect(response).to be_error
    expect(response.content.first[:text]).to include("requires start_target")
    expect(session).not_to have_received(:call_tool)
  end

  it "rejects a call missing end_target without touching the upstream browser" do
    response = described_class.call(start_target: "e1", server_context: ctx)

    expect(response).to be_error
    expect(response.content.first[:text]).to include("requires end_target")
    expect(session).not_to have_received(:call_tool)
  end
end
