require "rails_helper"

RSpec.describe SyrusBrowser::FileUploadTool do
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
    expect(described_class.tool_name).to eq("browser_file_upload")
  end

  it "has no required arguments, since omitting paths cancels the file chooser" do
    expect(described_class.input_schema_value.to_h[:required]).to eq([])
  end

  it "forwards paths to the upstream browser_file_upload tool" do
    allow(session).to receive(:call_tool).and_return({ "result" => { "content" => [] } })

    described_class.call(paths: [ "/tmp/screenshot.png" ], server_context: ctx)

    expect(session).to have_received(:call_tool).with(
      name: "browser_file_upload", arguments: { "paths" => [ "/tmp/screenshot.png" ] }
    )
  end

  it "allows calling with no paths to cancel the file chooser" do
    allow(session).to receive(:call_tool).and_return({ "result" => { "content" => [] } })

    described_class.call(server_context: ctx)

    expect(session).to have_received(:call_tool).with(name: "browser_file_upload", arguments: {})
  end
end
