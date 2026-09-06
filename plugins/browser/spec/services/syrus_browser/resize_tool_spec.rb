require "rails_helper"

RSpec.describe SyrusBrowser::ResizeTool do
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

  it "declares the browser_resize tool name" do
    expect(described_class.tool_name).to eq("browser_resize")
  end

  it "requires width and height" do
    expect(described_class.input_schema_value.to_h[:required]).to eq(%w[width height])
  end

  it "forwards width and height to the upstream browser_resize tool" do
    allow(session).to receive(:call_tool).and_return({ "result" => { "content" => [] } })

    described_class.call(width: 390, height: 844, server_context: ctx)

    expect(session).to have_received(:call_tool).with(
      name: "browser_resize", arguments: { "width" => 390, "height" => 844 }
    )
  end

  it "rejects a call missing width without touching the upstream browser" do
    response = described_class.call(height: 844, server_context: ctx)

    expect(response).to be_error
    expect(response.content.first[:text]).to include("requires width")
    expect(session).not_to have_received(:call_tool)
  end

  it "rejects a call missing height without touching the upstream browser" do
    response = described_class.call(width: 390, server_context: ctx)

    expect(response).to be_error
    expect(response.content.first[:text]).to include("requires height")
    expect(session).not_to have_received(:call_tool)
  end
end
