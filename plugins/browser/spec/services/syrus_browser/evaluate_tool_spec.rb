require "rails_helper"

RSpec.describe SyrusBrowser::EvaluateTool do
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
    expect(described_class.tool_name).to eq("browser_evaluate")
  end

  it "requires function" do
    expect(described_class.input_schema_value.to_h[:required]).to eq([ "function" ])
  end

  it "forwards element, target, and function to the upstream browser_evaluate tool" do
    allow(session).to receive(:call_tool).and_return({ "result" => { "content" => [] } })

    described_class.call(element: "Drop zone", target: "e7", function: "(el) => el.click()", server_context: ctx)

    expect(session).to have_received(:call_tool).with(
      name: "browser_evaluate",
      arguments: { "element" => "Drop zone", "target" => "e7", "function" => "(el) => el.click()" }
    )
  end

  it "accepts legacy ref as a target alias" do
    allow(session).to receive(:call_tool).and_return({ "result" => { "content" => [] } })

    described_class.call(element: "Drop zone", ref: "e7", function: "(el) => el.click()", server_context: ctx)

    expect(session).to have_received(:call_tool).with(
      name: "browser_evaluate",
      arguments: { "element" => "Drop zone", "target" => "e7", "function" => "(el) => el.click()" }
    )
  end

  it "allows evaluating without a target, for page-scoped functions" do
    allow(session).to receive(:call_tool).and_return({ "result" => { "content" => [] } })

    described_class.call(function: "() => document.title", server_context: ctx)

    expect(session).to have_received(:call_tool).with(
      name: "browser_evaluate", arguments: { "function" => "() => document.title" }
    )
  end

  it "rejects a call missing function without touching the upstream browser" do
    response = described_class.call(target: "e7", server_context: ctx)

    expect(response).to be_error
    expect(response.content.first[:text]).to include("requires function")
    expect(session).not_to have_received(:call_tool)
  end
end
