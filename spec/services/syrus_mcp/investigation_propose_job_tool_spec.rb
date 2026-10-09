require "rails_helper"

RSpec.describe Mcp::Tools::InvestigationProposeJobTool do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:source_job) do
    Job.create!(
      user: user,
      repository: repository,
      kind: "direct",
      issue_number: nil,
      issue_title: "Investigate flaky mutation results",
      issue_body: "Find out what is failing.",
      investigation: true
    )
  end
  let(:workflow) { Workflows::Investigation.instantiate(job: source_job) }
  let(:run) do
    step = workflow.steps.find_by!(kind: "investigate")
    step.runs.create!(job: source_job, trigger_kind: workflow.trigger_kind, agent_provider: workflow.agent_provider)
  end

  def call_tool(title: "Fix mutation timeout", description: "Make the mutation runner report timeouts clearly.", planned_execution: { capabilities: { os: [ "linux" ] } }, context_run: run)
    described_class.call(
      title: title,
      description: description,
      planned_execution: planned_execution,
      server_context: { run: context_run }
    )
  end

  def payload(response)
    JSON.parse(response.content.first[:text])
  end

  it "uses the workflow propose_job tool name" do
    expect(described_class.tool_name).to eq("propose_job")
  end

  it "creates a triaging follow-up Job without starting it" do
    response = call_tool

    expect(response).not_to be_error
    proposed = Job.find(payload(response).fetch("id"))
    expect(proposed).to have_attributes(
      repository: repository,
      kind: "direct",
      issue_title: "Fix mutation timeout",
      state: "triaging",
      triaging_reason: "proposed_job"
    )
    expect(proposed.issue_body).to include("Make the mutation runner report timeouts clearly.")
    expect(proposed.issue_body).to include(source_job.slug)
    expect(proposed.planned_execution_json).to include(
      "source" => "explicit",
      "capabilities" => { "os" => [ "linux" ] }
    )
    expect(proposed.workflows).to be_empty
    expect(workflow.reload.artifact("proposed_job_ids")).to eq([ proposed.id ])
  end

  it "rejects a proposal without declared capabilities" do
    response = call_tool(planned_execution: { project_label: "Backend" })

    expect(response).to be_error
    expect(response.content.first[:text]).to include("planned_execution.capabilities is required")
    expect(Job.where(issue_title: "Fix mutation timeout")).to be_empty
  end

  it "is not authorized from a non-investigation step" do
    implement_job = Factories.job
    response = call_tool(context_run: implement_job.initial_run)

    expect(response).to be_error
    expect(response.content.first[:text]).to include("not_authorized")
    expect(Job.where(issue_title: "Fix mutation timeout")).to be_empty
  end

  it "caps proposals from one investigation workflow" do
    workflow.set_artifact!("proposed_job_ids", (1..described_class::MAX_PROPOSALS_PER_WORKFLOW).to_a)

    response = call_tool

    expect(response).to be_error
    expect(response.content.first[:text]).to include("at most #{described_class::MAX_PROPOSALS_PER_WORKFLOW}")
  end
end
