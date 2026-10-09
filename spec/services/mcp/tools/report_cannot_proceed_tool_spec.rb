require "rails_helper"

RSpec.describe Mcp::Tools::ReportCannotProceedTool do
  let(:job) { Factories.job }
  let(:run) { job.initial_run }
  let(:workflow) { run.workflow }

  def call(**overrides)
    described_class.call(
      reason: "mull-runner is not installed on the worker",
      details: "`which mull-runner` returned nothing.",
      server_context: { run: run },
      **overrides
    )
  end

  it "exposes the expected tool name and required schema" do
    expect(described_class.tool_name).to eq("report_cannot_proceed")
    expect(described_class.input_schema_value.to_h[:required]).to eq(%w[reason])
  end

  it "records the reason as workflow artifact, warning, job attention, and audit log" do
    expect { call }.to change(WorkflowWarning, :count).by(1)

    expect(workflow.reload.artifact("cannot_proceed")).to include(
      "reason" => "mull-runner is not installed on the worker",
      "details" => "`which mull-runner` returned nothing.",
      "run_id" => run.id,
      "step_id" => run.step_id
    )

    warning = WorkflowWarning.last
    expect(warning).to have_attributes(
      job: job,
      workflow: workflow,
      step: run.step,
      kind: "agent_cannot_proceed",
      severity: "high",
      state: "pending"
    )
    expect(warning.title).to include("mull-runner is not installed")
    expect(warning.suggested_prompt).to include("Resolve the workflow blocker")
    expect(job.reload.needs_attention_reason).to eq("agent_cannot_proceed")
    expect(run.job_logs.last.chunk).to include("[mcp] report_cannot_proceed")
  end

  it "rejects a blank reason" do
    response = call(reason: " ")

    expect(response).to be_error
    expect(response.content.first[:text]).to include("reason is required")
  end

  it "keeps a long valid reason in evidence while capping the warning title to the schema limit" do
    long_reason = "missing worker dependency " + ("x" * 520)

    response = call(reason: long_reason)

    expect(response).not_to be_error
    warning = WorkflowWarning.last
    expect(warning.title.length).to be <= Mcp::Tools::ReportCannotProceedTool::MAX_WARNING_TITLE_LENGTH
    expect(warning.evidence.fetch("reason").length).to eq(Mcp::Tools::ReportCannotProceedTool::MAX_REASON_LENGTH)
    expect(workflow.reload.artifact("cannot_proceed").fetch("reason").length).to eq(Mcp::Tools::ReportCannotProceedTool::MAX_REASON_LENGTH)
    expect(job.reload.needs_attention_reason).to eq("agent_cannot_proceed")
  end
end
