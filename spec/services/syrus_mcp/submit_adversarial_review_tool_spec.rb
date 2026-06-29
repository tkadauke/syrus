require "rails_helper"

RSpec.describe SyrusMcp::SubmitAdversarialReviewTool do
  let(:run) { Factories.job.initial_run }

  def call(critique: "The implementation needs a missing edge-case test.", verdict: "needs_work")
    described_class.call(critique: critique, verdict: verdict, server_context: { run: run })
  end

  it "accepts a run_id-only sidecar context" do
    described_class.call(
      critique: "No blocking issues found.",
      verdict: "approved",
      server_context: { run_id: run.id }
    )

    expect(run.workflow.reload.artifact("adversarial_review_iterations")).to eq([
      {
        "iteration" => run.step.iteration,
        "critique" => "No blocking issues found.",
        "verdict" => "approved"
      }
    ])
  end

  it "appends each review to the workflow artifact" do
    run.workflow.set_artifact!("adversarial_review_iterations", [
      { "iteration" => 1, "critique" => "First pass.", "verdict" => "needs_work" }
    ])

    call(critique: "Second pass is clean.", verdict: "approved")

    expect(run.workflow.reload.artifact("adversarial_review_iterations")).to eq([
      { "iteration" => 1, "critique" => "First pass.", "verdict" => "needs_work" },
      { "iteration" => run.step.iteration, "critique" => "Second pass is clean.", "verdict" => "approved" }
    ])
  end

  it "normalizes binary-tagged UTF-8 and strips whitespace" do
    call(critique: "  Check ● paths.  ".b, verdict: " approved ".b)

    artifact = run.workflow.reload.artifact("adversarial_review_iterations").last
    expect(artifact).to include("critique" => "Check ● paths.", "verdict" => "approved")
    expect(artifact["critique"].encoding).to eq(Encoding::UTF_8)
  end

  it "rejects empty critique" do
    response = call(critique: " ")

    expect(response).to be_error
    expect(response.content.first[:text]).to include("critique is required")
    expect(run.workflow.reload.artifact("adversarial_review_iterations")).to be_nil
  end

  it "rejects unsupported verdicts" do
    response = call(verdict: "maybe")

    expect(response).to be_error
    expect(response.content.first[:text]).to include("verdict must be one of")
    expect(run.workflow.reload.artifact("adversarial_review_iterations")).to be_nil
  end

  it "writes a JobLog audit line" do
    expect { call(verdict: "approved") }.to change { run.job_logs.count }.by(1)
    expect(run.job_logs.last.chunk).to include("[mcp] submit_adversarial_review received: approved")
  end

  it "exposes the expected tool name and required schema" do
    expect(described_class.tool_name).to eq("submit_adversarial_review")
    expect(described_class.input_schema_value.to_h[:required]).to match_array(%w[critique verdict])
  end
end
