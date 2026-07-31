require "rails_helper"

RSpec.describe SyrusMcp::ReadRunWorkerHealthTool do
  let(:run) { Factories.job.initial_run }

  def payload_from(response)
    JSON.parse(response.content.first[:text])
  end

  it "returns worker health correlation for the current run by default" do
    run.workflow.update!(worker_hostname: "worker-a")
    run.update!(started_at: 10.minutes.ago, finished_at: 1.minute.ago)
    WorkerHostHealthSample.create!(
      hostname: "worker-a",
      role: "worker",
      version: "abc123",
      observed_at: 5.minutes.ago,
      cpu_pressure_some: 25.0
    )

    response = described_class.call(server_context: { run_id: run.id })

    expect(response).not_to be_error
    payload = payload_from(response)
    expect(payload["run_id"]).to eq(run.id)
    expect(payload["primary_hostname"]).to eq("worker-a")
    expect(payload.dig("pressure", "level")).to eq("warning")
  end

  it "allows same-repository run lookup for insight comparisons" do
    other_run = Run.create!(
      job: run.job,
      user: run.user,
      step: run.step,
      trigger_kind: "initial",
      started_at: 10.minutes.ago,
      finished_at: 1.minute.ago
    )
    run.workflow.update!(worker_hostname: "worker-a")

    response = described_class.call(server_context: { run_id: run.id }, run_id: other_run.id)

    expect(response).not_to be_error
    expect(payload_from(response)["run_id"]).to eq(other_run.id)
  end

  it "rejects run lookup outside the current repository scope" do
    foreign_run = Factories.job.initial_run

    response = described_class.call(server_context: { run_id: run.id }, run_id: foreign_run.id)

    expect(response).to be_error
    expect(response.content.first[:text]).to include("outside this repository scope")
  end

  it "is advertised to workflow and insight agents" do
    expect(McpToolPolicy.for(McpToolContext.from_run(run))).to include(described_class)

    Feature.find_or_create_by!(slug: "agent_insights") do |feature|
      feature.category = "Labs"
      feature.name = "Agent Insights"
    end.update!(enabled: true)
    Feature.clear_enabled_cache!("agent_insights")
    insight_job = Factories.job_record(user: run.user, repository: run.job.repository, kind: "agent_insight", issue_number: nil)
    insight_workflow = Workflows::AgentInsight.instantiate(job: insight_job)
    insight_step = insight_workflow.steps.find_by!(kind: "agent_insight_run")
    insight_run = Run.create!(job: insight_job, user: run.user, step: insight_step, trigger_kind: "agent_insight")

    expect(McpToolPolicy.for(McpToolContext.from_run(insight_run))).to include(described_class)
  end
end
