require "rails_helper"

RSpec.describe SyrusMcp::SubmitTestPlanTool do
  let(:run) { Factories.job.initial_run }

  def call(steps: [ "Run bin/rspec spec/services/steps/test_plan_spec.rb" ], notes: "Focus on the initial workflow.")
    described_class.call(steps: steps, notes: notes, server_context: { run: run })
  end

  it "accepts a run_id-only sidecar context" do
    described_class.call(
      steps: [ "Open /jobs/1 and verify the Test Plan section." ],
      server_context: { run_id: run.id }
    )

    expect(run.workflow.reload.artifact("test_plan")).to include(
      "steps" => [ "Open /jobs/1 and verify the Test Plan section." ],
      "notes" => nil
    )
  end

  it "persists steps and notes on the workflow artifact" do
    call(
      steps: [ "Run bin/rspec", "Open the PR and inspect ## Test Plan." ],
      notes: "Covers the new MCP handoff."
    )

    expect(run.workflow.reload.artifact("test_plan")).to eq(
      "steps" => [ "Run bin/rspec", "Open the PR and inspect ## Test Plan." ],
      "notes" => "Covers the new MCP handoff."
    )
  end

  it "normalizes binary-tagged UTF-8 and strips blank steps" do
    call(steps: [ "Run ● spec".b, "  " ], notes: "Review ● output.".b)

    artifact = run.workflow.reload.artifact("test_plan")
    expect(artifact).to eq("steps" => [ "Run ● spec" ], "notes" => "Review ● output.")
    expect(artifact["steps"].first.encoding).to eq(Encoding::UTF_8)
  end

  it "rejects an empty steps list" do
    response = call(steps: [ " " ])

    expect(response).to be_error
    expect(response.content.first[:text]).to include("steps must include at least one item")
    expect(run.workflow.reload.artifact("test_plan")).to be_nil
  end

  it "writes a JobLog audit line" do
    expect { call(steps: [ "Run bin/rspec" ]) }.to change { run.job_logs.count }.by(1)
    expect(run.job_logs.last.chunk).to include("[mcp] submit_test_plan received: 1 step(s)")
  end

  it "exposes the expected tool name and required schema" do
    expect(described_class.tool_name).to eq("submit_test_plan")
    expect(described_class.input_schema_value.to_h[:required]).to eq(%w[steps])
  end
end
