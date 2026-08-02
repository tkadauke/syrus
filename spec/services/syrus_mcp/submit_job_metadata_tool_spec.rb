require "rails_helper"

RSpec.describe SyrusMcp::SubmitJobMetadataTool do
  let(:run) { Factories.job.initial_run }

  before do
    run.step.update_columns(kind: "refresh_job_metadata")
  end

  def call(**args)
    described_class.call(
      **{
        changed: true,
        title: "Preserve provider switching",
        summary: "The Job now preserves an explicit provider switching path.",
        pr_body: "Preserves provider switching while keeping provider selection pinned by default.",
        test_plan: { steps: [ "Run bin/rspec spec/services/provider_spec.rb" ], notes: "Review the PR copy." },
        intent_revision_reason: "Feedback changed the intended provider-switching behavior.",
        server_context: { run: run }
      }.merge(args)
    )
  end

  it "stores normalized canonical metadata on the Workflow" do
    call(title: "  Preserve provider switching  ", test_plan: { "steps" => [ " Run tests ", "" ], "notes" => " Check UI " })

    expect(run.workflow.reload.artifact("job_metadata")).to include(
      "changed" => true,
      "title" => "Preserve provider switching",
      "summary" => "The Job now preserves an explicit provider switching path.",
      "pr_body" => "Preserves provider switching while keeping provider selection pinned by default.",
      "test_plan" => { "steps" => [ "Run tests" ], "notes" => "Check UI" },
      "intent_revision_reason" => "Feedback changed the intended provider-switching behavior."
    )
  end

  it "allows an explicit no-change submission with only a reason" do
    response = call(changed: false, title: nil, summary: nil, pr_body: nil, test_plan: nil, intent_revision_reason: "Only fixed a typo.")

    expect(response).not_to be_error
    expect(run.workflow.reload.artifact("job_metadata")).to include(
      "changed" => false,
      "intent_revision_reason" => "Only fixed a typo."
    )
  end

  it "rejects changed=true without required canonical fields" do
    response = call(title: "")

    expect(response).to be_error
    expect(response.content.first[:text]).to include("title is required")
    expect(run.workflow.reload.artifact("job_metadata")).to be_nil
  end

  it "requires test plan steps when changed=true" do
    response = call(test_plan: { steps: [] })

    expect(response).to be_error
    expect(response.content.first[:text]).to include("test_plan.steps")
  end

  it "writes an audit log line" do
    expect { call(changed: false, intent_revision_reason: "No metadata change.") }.to change { run.job_logs.count }.by(1)
    expect(run.job_logs.last.chunk).to include("[mcp] submit_job_metadata received")
  end

  it "exposes the dedicated tool name" do
    expect(described_class.tool_name).to eq("submit_job_metadata")
  end
end
