require "rails_helper"

RSpec.describe Mcp::Tools::SubmitReportTool do
  let(:job) do
    Factories.job(
      kind: "direct",
      issue_number: nil,
      issue_title: "Investigation: what's slow?",
      issue_body: "Investigate: why does /dashboard feel slow?",
      investigation: true
    )
  end
  let(:run) { job.workflows.last.first_step.runs.first }

  def call(title: "Dashboard slowness", narrative: "It's slow because of an N+1 query.", findings: nil)
    described_class.call(title: title, narrative: narrative, findings: findings, server_context: { run: run })
  end

  it "accepts a run_id-only sidecar context" do
    described_class.call(
      title: "Dashboard slowness",
      narrative: "It's slow because of an N+1 query.",
      server_context: { run_id: run.id }
    )

    expect(run.workflow.reload.artifact("investigation_report")).to include(
      "title" => "Dashboard slowness",
      "narrative" => "It's slow because of an N+1 query."
    )
  end

  it "persists title, narrative, and findings on the workflow artifact" do
    call(findings: [ "N+1 query in DashboardController#index", "Missing index on jobs.repository_id" ])

    expect(run.workflow.reload.artifact("investigation_report")).to eq(
      "title" => "Dashboard slowness",
      "narrative" => "It's slow because of an N+1 query.",
      "findings" => [ "N+1 query in DashboardController#index", "Missing index on jobs.repository_id" ]
    )
  end

  it "defaults findings to an empty list when omitted" do
    call

    expect(run.workflow.reload.artifact("investigation_report")["findings"]).to eq([])
  end

  it "normalizes binary-tagged UTF-8 and truncates oversized fields" do
    call(title: "Slow ● dashboard".b, narrative: ("Evidence. " * 3000).b, findings: [ "Finding ● one".b ])

    artifact = run.workflow.reload.artifact("investigation_report")
    expect(artifact["title"]).to eq("Slow ● dashboard")
    expect(artifact["title"].encoding).to eq(Encoding::UTF_8)
    expect(artifact["narrative"].length).to be <= described_class::MAX_NARRATIVE_LENGTH
    expect(artifact["findings"]).to eq([ "Finding ● one" ])
  end

  it "caps findings at MAX_FINDINGS and drops blanks" do
    findings = (1..15).map { |n| "Finding #{n}" } + [ "  " ]
    call(findings: findings)

    artifact = run.workflow.reload.artifact("investigation_report")
    expect(artifact["findings"].size).to eq(described_class::MAX_FINDINGS)
    expect(artifact["findings"]).to eq((1..described_class::MAX_FINDINGS).map { |n| "Finding #{n}" })
  end

  it "rejects a blank title" do
    response = call(title: "  ")

    expect(response).to be_error
    expect(response.content.first[:text]).to include("title is required")
    expect(run.workflow.reload.artifact("investigation_report")).to be_nil
  end

  it "rejects a blank narrative" do
    response = call(narrative: "  ")

    expect(response).to be_error
    expect(response.content.first[:text]).to include("narrative is required")
    expect(run.workflow.reload.artifact("investigation_report")).to be_nil
  end

  it "writes a JobLog audit line" do
    expect { call }.to change { run.job_logs.count }.by(1)
    expect(run.job_logs.last.chunk).to include("[mcp] submit_report received: \"Dashboard slowness\"")
  end

  it "exposes the expected tool name and required schema" do
    expect(described_class.tool_name).to eq("submit_report")
    schema = described_class.input_schema_value.to_h
    expect(schema[:required]).to eq(%w[title narrative])
  end
end
