require "rails_helper"

RSpec.describe SyrusMcp::PatchWorkflowTool do
  let(:run) { Factories.job.initial_run }

  def call_tool(step_kinds: [ "visual_review" ], reason: "UI change needs visual QA", after_kind: "implement")
    described_class.call(
      step_kinds: step_kinds,
      reason: reason,
      after_kind: after_kind,
      server_context: { run: run }
    )
  end

  it "returns a tool error instead of raising when WorkflowPatch fails unexpectedly" do
    allow(WorkflowPatch).to receive(:apply!).and_raise(ActiveRecord::StatementInvalid, "database temporarily unavailable")

    response = nil
    expect { response = call_tool }.not_to raise_error

    expect(response).to be_error
    expect(response.content.first[:text]).to include("ActiveRecord::StatementInvalid")
    expect(response.content.first[:text]).to include("database temporarily unavailable")
    expect(response.content.first[:text]).not_to include("Internal error calling tool patch_workflow")
  end
end
