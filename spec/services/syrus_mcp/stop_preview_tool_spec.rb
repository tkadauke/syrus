require "rails_helper"

RSpec.describe Mcp::Tools::StopPreviewTool do
  let(:run) { Factories.job.initial_run }

  def call
    described_class.call(server_context: { run: run })
  end

  before  { Mcp::Tools::AgentPreviewRegistry.reset! }
  after   { Mcp::Tools::AgentPreviewRegistry.reset! }

  it "exposes the expected tool name" do
    expect(described_class.tool_name).to eq("stop_preview")
  end

  it "returns success" do
    response = call
    expect(response).not_to be_error
    expect(response.content.first[:text]).to eq("Preview stopped.")
  end

  it "writes a JobLog audit line" do
    expect { call }.to change { run.job_logs.count }.by(1)
    expect(run.job_logs.last.chunk).to include("[mcp] stop_preview")
  end

  context "when a preview is registered" do
    before { Mcp::Tools::AgentPreviewRegistry.register(run_id: run.id, pid: 9999, port: 3001) }

    it "removes the run from the registry" do
      call
      expect(Mcp::Tools::AgentPreviewRegistry.get(run.id)).to be_nil
    end

    it "calls kill on the registry for this run" do
      expect(Mcp::Tools::AgentPreviewRegistry).to receive(:kill).with(run.id).and_call_original
      call
    end
  end

  context "when no preview is running" do
    it "is a no-op and still returns success" do
      expect(Mcp::Tools::AgentPreviewRegistry).to receive(:kill).with(run.id).and_call_original
      response = call
      expect(response).not_to be_error
    end
  end
end
