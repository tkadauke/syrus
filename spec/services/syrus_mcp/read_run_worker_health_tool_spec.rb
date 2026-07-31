require "rails_helper"

RSpec.describe Mcp::Tools::ReadRunWorkerHealthTool do
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
    CommandSpan.create!(
      job: run.job,
      workflow: run.workflow,
      step: run.step,
      run: run,
      sequence: 1,
      name: "bundle check",
      command_excerpt: "bundle check",
      hostname: "worker-a",
      started_at: 6.minutes.ago,
      finished_at: 4.minutes.ago,
      duration_ms: 120_000,
      outcome: "succeeded",
      exit_status: 0
    )

    response = described_class.call(server_context: { run_id: run.id })

    expect(response).not_to be_error
    payload = payload_from(response)
    expect(payload["run_id"]).to eq(run.id)
    expect(payload["primary_hostname"]).to eq("worker-a")
    expect(payload.dig("pressure", "level")).to eq("warning")
    expect(payload.dig("command_spans", 0, "name")).to eq("bundle check")
  end

  it "does not expose GitHub credentials in read_run_worker_health output" do
    SpawnedProcess.create!(
      run: run,
      workflow: run.workflow,
      kind: "git",
      command: "git fetch https://x-access-token:ghp_mcpsecret@github.com/acme/widgets.git",
      hostname: "worker-a",
      started_at: 6.minutes.ago,
      finished_at: 4.minutes.ago,
      outcome: "succeeded"
    )

    response = described_class.call(server_context: { run_id: run.id })
    text = response.content.first[:text]

    expect(response).not_to be_error
    expect(text).to include("https://x-access-token:[REDACTED]@github.com/acme/widgets.git")
    expect(text).not_to include("ghp_mcpsecret")
    expect(text).not_to include("x-access-token:ghp_")
  end

  it "redacts structured command copies at the MCP serialization boundary" do
    allow(WorkerHealthRunCorrelation).to receive(:for_run).with(run, sample_limit: 20).and_return(
      {
        run_id: run.id,
        processes: [
          {
            command: "git clone https://x-access-token:ghs_boundarysecret@github.com/acme/widgets.git"
          }
        ],
        command_spans: [
          {
            command_excerpt: "git ls-remote https://x-access-token:ghs_spanboundary@github.com/acme/widgets.git",
            metadata: {
              "command_excerpt" => "git clone https://x-access-token:github_pat_boundarysecret@github.com/acme/widgets.git"
            }
          }
        ]
      }
    )

    response = described_class.call(server_context: { run_id: run.id })
    text = response.content.first[:text]

    expect(response).not_to be_error
    expect(text).to include("git clone https://x-access-token:[REDACTED]@github.com/acme/widgets.git")
    expect(text).to include("git ls-remote https://x-access-token:[REDACTED]@github.com/acme/widgets.git")
    expect(text).not_to include("ghs_boundarysecret")
    expect(text).not_to include("ghs_spanboundary")
    expect(text).not_to include("github_pat_boundarysecret")
    expect(text).not_to include("x-access-token:ghs_")
    expect(text).not_to include("x-access-token:github_pat_")
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
