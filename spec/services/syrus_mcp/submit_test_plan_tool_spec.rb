require "rails_helper"

RSpec.describe Mcp::Tools::SubmitTestPlanTool do
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
      "notes" => "Covers the new MCP handoff.",
      "visual_review_recommended" => nil,
      "visual_review_reason" => nil
    )
  end

  it "normalizes binary-tagged UTF-8 and strips blank steps" do
    call(steps: [ "Run ● spec".b, "  " ], notes: "Review ● output.".b)

    artifact = run.workflow.reload.artifact("test_plan")
    expect(artifact).to eq(
      "steps" => [ "Run ● spec" ],
      "notes" => "Review ● output.",
      "visual_review_recommended" => nil,
      "visual_review_reason" => nil
    )
    expect(artifact["steps"].first.encoding).to eq(Encoding::UTF_8)
  end

  it "accepts newline-separated steps as a simpler valid MCP argument shape" do
    call(
      steps: "Run bin/rspec spec/services/syrus_mcp/submit_test_plan_tool_spec.rb\nOpen /jobs/1 and inspect the Test Plan section.\n\n"
    )

    expect(run.workflow.reload.artifact("test_plan")).to include(
      "steps" => [
        "Run bin/rspec spec/services/syrus_mcp/submit_test_plan_tool_spec.rb",
        "Open /jobs/1 and inspect the Test Plan section."
      ]
    )
  end

  it "keeps generated test plans compact" do
    long_step = "Open /jobs/1 and " + ("verify the changed dashboard filter behavior " * 20)
    response = call(
      steps: [
        "Run bin/rspec",
        long_step,
        "Open the PR",
        "Check the summary",
        "Review the source diff",
        "This sixth step should be ignored"
      ],
      notes: "Reviewer context. " * 80
    )

    expect(response).not_to be_error
    artifact = run.workflow.reload.artifact("test_plan")
    expect(artifact["steps"].size).to eq(5)
    expect(artifact["steps"].second.length).to be <= described_class::MAX_STEP_LENGTH
    expect(artifact["steps"]).not_to include("This sixth step should be ignored")
    expect(artifact["notes"].length).to be <= described_class::MAX_NOTES_LENGTH
  end

  it "persists the implementer's visual_review recommendation and reason" do
    described_class.call(
      steps: [ "Open /dashboard and check the new banner." ],
      notes: nil,
      visual_review_recommended: true,
      visual_review_reason: "Added a new banner to the dashboard header.",
      server_context: { run: run }
    )

    expect(run.workflow.reload.artifact("test_plan")).to include(
      "visual_review_recommended" => true,
      "visual_review_reason" => "Added a new banner to the dashboard header."
    )
  end

  it "normalizes binary-tagged UTF-8 in visual_review_reason" do
    described_class.call(
      steps: [ "Run bin/rspec" ],
      notes: nil,
      visual_review_recommended: false,
      visual_review_reason: "  Backend-only change ●.  ".b,
      server_context: { run: run }
    )

    artifact = run.workflow.reload.artifact("test_plan")
    expect(artifact["visual_review_reason"]).to eq("Backend-only change ●.")
    expect(artifact["visual_review_reason"].encoding).to eq(Encoding::UTF_8)
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
    schema = described_class.input_schema_value.to_h
    expect(schema[:required]).to eq(%w[steps])
    expect(schema.dig(:properties, :steps, :oneOf).map { |candidate| candidate[:type] }).to eq(%w[array string])
    expect(schema.dig(:properties, :steps, :oneOf, 0, :maxItems)).to eq(described_class::MAX_STEPS)
    expect(schema.dig(:properties, :notes, :maxLength)).to eq(described_class::MAX_NOTES_LENGTH)
  end
end
