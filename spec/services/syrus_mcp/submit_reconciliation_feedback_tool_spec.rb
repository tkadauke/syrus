require "rails_helper"

RSpec.describe Mcp::Tools::SubmitReconciliationFeedbackTool do
  let(:user)       { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  # Set up a feedback-mode Epic with a reconciliation Job.
  # Create the job without the epic so it gets an initial run, then wire the relationship.
  let(:epic) { Factories.epic(user: user, repository: repository, reconciliation_mode: "feedback") }
  let(:recon_job) { Factories.job(user: user, repository: repository) }
  let(:run) do
    recon_job.update!(epic: epic)
    epic.update!(reconciliation_job_id: recon_job.id)
    recon_job.initial_run
  end

  # A sibling Job that the reconciliation agent will submit feedback to.
  let(:target_job) do
    j = Factories.job_record(user: user, repository: repository)
    j.update_columns(state: "approved")
    j.reload
  end

  def call(job_id: target_job.id, feedback: "The naming convention differs from sibling Job.")
    described_class.call(job_id: job_id, feedback: feedback, server_context: { run: run })
  end

  it "returns not_authorized when called from a standard implement-role run" do
    implement_run = Factories.job.initial_run
    response = described_class.call(
      job_id: target_job.id,
      feedback: "Fix the naming.",
      server_context: { run: implement_run }
    )

    expect(response).to be_error
    payload = JSON.parse(response.content.first[:text], symbolize_names: true)
    expect(payload).to eq(error: "not_authorized")
  end

  it "creates a chat_feedback workflow on the target Job" do
    expect { call }.to change { target_job.workflows.where(trigger_kind: "chat_feedback").count }.by(1)
  end

  it "returns a success response" do
    response = call
    expect(response).not_to be_error
    expect(response.content.first[:text]).to include(target_job.slug)
  end

  it "writes a JobLog audit line on the reconciliation run" do
    expect { call }.to change { run.job_logs.count }.by(1)
    expect(run.job_logs.last.chunk).to include("[mcp] submit_chat_feedback")
    expect(run.job_logs.last.chunk).to include(target_job.slug)
  end

  it "accepts a run_id-only sidecar context" do
    response = described_class.call(
      job_id: target_job.id,
      feedback: "Fix the naming.",
      server_context: { run_id: run.id }
    )
    expect(response).not_to be_error
  end

  it "rejects blank feedback" do
    response = call(feedback: "   ")
    expect(response).to be_error
    expect(response.content.first[:text]).to include("feedback is required")
  end

  it "returns an error when the target job is not found" do
    response = call(job_id: 0)
    expect(response).to be_error
    expect(response.content.first[:text]).to include("not found")
  end

  it "returns an error when the target job is in a non-actionable state" do
    closed_job = Factories.job_record(user: user, repository: repository)
    response = call(job_id: closed_job.id)
    expect(response).to be_error
    expect(response.content.first[:text]).to include("not actionable")
  end

  it "exposes the expected tool name and required schema" do
    expect(described_class.tool_name).to eq("submit_chat_feedback")
    expect(described_class.input_schema_value.to_h[:required]).to match_array(%w[job_id feedback])
  end
end
