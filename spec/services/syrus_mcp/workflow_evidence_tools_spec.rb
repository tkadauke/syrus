require "rails_helper"

RSpec.describe "SyrusMcp workflow evidence tools" do
  let!(:bootstrap_admin) { Factories.user(admin: true) }
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:insight_run) { build_insight_run(user: user, repository: repository) }

  before do
    Feature.find_or_create_by!(slug: "agent_insights") do |feature|
      feature.category = "Labs"
      feature.name = "Agent Insights"
    end.update!(enabled: true)
    Feature.clear_enabled_cache!("agent_insights")
  end

  def build_insight_run(user:, repository:, finished_at: nil)
    job = Job.create!(
      user: user,
      repository: repository,
      kind: "agent_insight",
      priority: "low",
      finished_at: finished_at
    )
    workflow = Workflow.create!(
      job: job,
      trigger_kind: "agent_insight",
      agent_provider: user.agent_provider,
      chain_template: []
    )
    step = Step.create!(workflow: workflow, kind: "agent_insight_run", position: 0)
    step.runs.create!(job: job, trigger_kind: "agent_insight", agent_provider: user.agent_provider)
  end

  def build_completed_workflow(repository:, user: repository.user, finished_at:,
                               title: "Implement useful change", log_chunks: [])
    job = Factories.job(repository: repository, user: user, issue_title: title)
    workflow = job.latest_workflow
    workflow.update!(
      state: "succeeded",
      started_at: finished_at - 2.minutes,
      finished_at: finished_at
    )
    step = workflow.steps.first
    step.update!(state: "succeeded", started_at: finished_at - 2.minutes, finished_at: finished_at - 1.minute)
    run = step.runs.first
    run.update!(
      state: "succeeded",
      agent_outcome: "success",
      agent_summary: "used CODEX_API_KEY=sk-secret-value-abcdefghijklmnop",
      agent_diff: "diff contains https://x-access-token:ghp_secretvalueabcdefghijklmnop@github.com/acme/widgets.git",
      started_at: finished_at - 2.minutes,
      finished_at: finished_at - 1.minute
    )
    log_chunks.each_with_index do |chunk, index|
      run.job_logs.create!(sequence: index, kind: "system", chunk: chunk)
    end
    [ workflow, run ]
  end

  def server
    MCP::Server.new(
      name: "syrus-mcp-sidecar",
      tools: McpToolPolicy.for(McpToolContext.from_run(insight_run)),
      server_context: { run_id: insight_run.id }
    )
  end

  def call_tool(name, arguments)
    raw = server.handle_json(
      { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: name, arguments: arguments } }.to_json
    )
    JSON.parse(raw, symbolize_names: true)
  end

  def response_payload(response)
    JSON.parse(response.fetch(:result).fetch(:content).first.fetch(:text), symbolize_names: true)
  end

  it "advertises workflow evidence tools to agent insight runs" do
    raw = server.handle_json({ jsonrpc: "2.0", id: 1, method: "tools/list", params: {} }.to_json)
    response = JSON.parse(raw, symbolize_names: true)

    tool_names = response.fetch(:result).fetch(:tools).map { |tool| tool.fetch(:name) }
    expect(tool_names).to include("list_recent_workflows", "read_run_transcript")
  end

  it "lets an insight run discover recent completed workflows and read their transcript through MCP" do
    old_workflow, = build_completed_workflow(repository: repository, finished_at: 3.days.ago)
    recent_workflow, recent_run = build_completed_workflow(
      repository: repository,
      finished_at: 1.hour.ago,
      title: "Recent failure repair",
      log_chunks: [ "started", "failed with github_pat_secretvalueabcdefghijklmnop" ]
    )
    build_completed_workflow(repository: Factories.repository(user: user), finished_at: 30.minutes.ago)

    list_response = call_tool("list_recent_workflows", since: 2.days.ago.iso8601)
    list_payload = response_payload(list_response)

    expect(list_response[:result][:isError]).to be_falsey
    expect(list_payload[:repository]).to include(id: repository.id, slug: repository.slug)
    expect(list_payload[:workflows].map { |workflow| workflow[:id] }).to eq([ recent_workflow.id ])
    expect(list_payload[:workflows].map { |workflow| workflow[:id] }).not_to include(old_workflow.id)
    expect(list_payload[:workflows].first[:runs].map { |run| run[:id] }).to include(recent_run.id)

    transcript_response = call_tool("read_run_transcript", run_id: recent_run.id, page: 1, per: 1)
    transcript_payload = response_payload(transcript_response)

    expect(transcript_response[:result][:isError]).to be_falsey
    expect(transcript_payload).to include(run_id: recent_run.id, total_chunks: 2, page: 1, per: 1, total_pages: 2)
    expect(transcript_payload[:chunks]).to eq([ { sequence: 0, kind: "system", chunk: "started" } ])
  end

  it "defaults list_recent_workflows to the previous completed insight cutoff" do
    previous_finished_at = 6.hours.ago
    build_insight_run(user: user, repository: repository, finished_at: previous_finished_at)
    before_cutoff, = build_completed_workflow(repository: repository, finished_at: previous_finished_at - 1.minute)
    after_cutoff, = build_completed_workflow(repository: repository, finished_at: previous_finished_at + 1.minute)

    payload = response_payload(call_tool("list_recent_workflows", {}))

    expect(payload[:since]).to eq(previous_finished_at.iso8601)
    expect(payload[:workflows].map { |workflow| workflow[:id] }).to include(after_cutoff.id)
    expect(payload[:workflows].map { |workflow| workflow[:id] }).not_to include(before_cutoff.id)
  end

  it "rejects transcript reads outside the current repository" do
    _workflow, foreign_run = build_completed_workflow(
      repository: Factories.repository(user: user),
      finished_at: 1.hour.ago
    )

    response = call_tool("read_run_transcript", run_id: foreign_run.id)

    expect(response[:result][:isError]).to be(true)
    expect(response[:result][:content].first[:text]).to include("run_id is outside this repository scope")
  end

  it "redacts secret-shaped values from transcript payloads" do
    _workflow, run = build_completed_workflow(
      repository: repository,
      finished_at: 1.hour.ago,
      log_chunks: [
        "Authorization token=ghp_secretvalueabcdefghijklmnop",
        "password=hunter2"
      ]
    )

    payload_text = response_payload(call_tool("read_run_transcript", run_id: run.id, per: 10)).to_json

    expect(payload_text).to include("[redacted]")
    expect(payload_text).not_to include(
      "ghp_secretvalueabcdefghijklmnop",
      "sk-secret-value-abcdefghijklmnop",
      "hunter2"
    )
  end

  it "redacts secret-shaped values from workflow list summaries" do
    workflow, _run = build_completed_workflow(
      repository: repository,
      finished_at: 1.hour.ago,
      title: "Fix password=hunter2"
    )
    workflow.set_artifact!("summary", "Used API_KEY=sk-secret-value-abcdefghijklmnop")

    payload_text = response_payload(call_tool("list_recent_workflows", since: 2.days.ago.iso8601)).to_json

    expect(payload_text).to include("[redacted]")
    expect(payload_text).not_to include("hunter2", "sk-secret-value-abcdefghijklmnop")
  end
end
