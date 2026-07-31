require "rails_helper"

RSpec.describe Mcp::Tools::ReadJobTool do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  def server
    MCP::Server.new(
      name: "syrus-chat-sidecar",
      tools: [ described_class ],
      server_context: { chat_session: chat_session }
    )
  end

  def call_tool(arguments)
    raw = server.handle_json({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "read_job", arguments: arguments } }.to_json)
    JSON.parse(raw, symbolize_names: true)
  end

  def response_payload(response)
    JSON.parse(response.fetch(:result).fetch(:content).first.fetch(:text), symbolize_names: true)
  end

  it "returns metadata, latest workflow summary, and transcript head/tail" do
    job = Factories.job(repository: repository, issue_number: 123, issue_title: "Fix the aqueduct", branch_name: "syrus/issue-123", pr_number: 9)
    upstream = Factories.job_record(user: user, repository: repository, issue_title: "Survey the aqueduct", state: "closed")
    JobDependency.create!(job: job, depends_on_job: upstream, source: "manual")
    JobDependency.create!(
      job: job,
      unresolved_owner: repository.owner,
      unresolved_repo: repository.name,
      unresolved_number: 456,
      source: "parsed"
    )
    workflow = job.latest_workflow
    workflow.set_artifact!("summary", "Raised the aqueduct by one cubit.")
    run = workflow.first_step.latest_run
    run.job_logs.create!(sequence: 0, kind: "stdout", chunk: "head-" + ("a" * 9.kilobytes))
    run.job_logs.create!(sequence: 1, kind: "stdout", chunk: "tail")

    response = call_tool(job_id: job.id)
    payload = response_payload(response)

    expect(response[:result][:isError]).to be_falsey
    expect(payload[:job]).to include(id: job.id, issue_number: 123, pr_number: 9, branch_name: "syrus/issue-123", agent_provider: "claude")
    expect(payload[:job]).to include(commits_behind_base: nil)
    expect(payload[:job][:dependencies]).to contain_exactly(
      include(id: upstream.id, issue_title: "Survey the aqueduct"),
      include(pending: true, unresolved_ref: "#{repository.owner}/#{repository.name}#456", source: "parsed")
    )
    expect(payload[:workflow_count]).to eq(1)
    expect(payload[:workflows_index]).to contain_exactly(a_hash_including(id: workflow.id, trigger_kind: "initial", summary: "Raised the aqueduct by one cubit.", run_count: 1))
    expect(payload[:latest_workflow]).to include(id: workflow.id, trigger_kind: "initial", summary: "Raised the aqueduct by one cubit.")
    expect(payload[:transcript]).to include(truncated: true)
    expect(payload[:transcript][:head]).to start_with("head-")
    expect(payload[:transcript][:tail]).to include("tail")
  end

  it "includes commits_behind_base when the job has a known staleness distance" do
    job = Factories.job(repository: repository)
    job.update_column(:commits_behind_base, 7)

    response = call_tool(job_id: job.id)
    payload = response_payload(response)

    expect(response[:result][:isError]).to be_falsey
    expect(payload[:job]).to include(commits_behind_base: 7)
  end

  it "includes landed_sha and configured deployment stages for landed jobs" do
    staging = SyrusYml::DeploymentStage.new(name: "staging", label: "Staging", tag: "staging", tag_pattern: nil)
    production = SyrusYml::DeploymentStage.new(name: "production", label: "Production", tag: "production", tag_pattern: nil)
    allow(RepoDeploymentStagesReader).to receive(:for_repository).with(repository).and_return(
      RepoDeploymentStagesReader::Result.new(stages: [ staging, production ], source: ".syrus.yml", note: nil)
    )
    job = Factories.job(repository: repository, landed_sha: "merge-sha", state: "closed")
    reached_at = Time.zone.parse("2026-07-30T12:00:00Z")
    job.deployment_stage_statuses.create!(stage_name: "staging", reached_at: reached_at, tag_sha: "tag-sha")

    response = call_tool(job_id: job.id)
    payload = response_payload(response)

    expect(response[:result][:isError]).to be_falsey
    expect(payload[:job]).to include(landed_sha: "merge-sha")
    expect(payload[:job][:deployment_stages]).to eq([
      { name: "staging", label: "Staging", reached: true, reached_at: reached_at.iso8601, tag_sha: "tag-sha" },
      { name: "production", label: "Production", reached: false, reached_at: nil, tag_sha: nil }
    ])
  end

  it "omits deployment stages for jobs that have not landed" do
    expect(RepoDeploymentStagesReader).not_to receive(:for_repository)
    job = Factories.job(repository: repository, landed_sha: nil)

    response = call_tool(job_id: job.id)
    payload = response_payload(response)

    expect(response[:result][:isError]).to be_falsey
    expect(payload[:job]).to include(landed_sha: nil)
    expect(payload[:job]).not_to have_key(:deployment_stages)
  end

  it "omits deployment stages when the repository has none configured" do
    allow(RepoDeploymentStagesReader).to receive(:for_repository).with(repository).and_return(
      RepoDeploymentStagesReader::Result.new(stages: [], source: "none", note: "no deployment_stages configured")
    )
    job = Factories.job(repository: repository, landed_sha: "merge-sha", state: "closed")

    response = call_tool(job_id: job.id)
    payload = response_payload(response)

    expect(response[:result][:isError]).to be_falsey
    expect(payload[:job]).to include(landed_sha: "merge-sha")
    expect(payload[:job]).not_to have_key(:deployment_stages)
  end

  it "reads jobs outside the chat repository when they belong to the chat user" do
    other = Factories.job(repository: Factories.repository(user: user))

    response = call_tool(job_id: other.id)
    payload = response_payload(response)

    expect(response[:result][:isError]).to be_falsey
    expect(payload[:job]).to include(id: other.id)
  end

  it "allows an admin to read another user's job" do
    admin = Factories.user(admin: true)
    other_job = Factories.job(repository: Factories.repository(user: Factories.user))
    admin_session = ChatSession.create!(user: admin)
    admin_server = MCP::Server.new(
      name: "syrus-chat-sidecar",
      tools: [ described_class ],
      server_context: { chat_session: admin_session }
    )

    raw = admin_server.handle_json({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "read_job", arguments: { job_id: other_job.id } } }.to_json)
    response = JSON.parse(raw, symbolize_names: true)

    expect(response[:result][:isError]).to be_falsey
    expect(response_payload(response)[:job]).to include(id: other_job.id)
  end

  it "includes epic dependencies in the dependency list" do
    job = Factories.job(repository: repository)
    upstream_epic = Factories.epic(repository: repository, user: user, title: "Aqueduct surveying")
    JobDependency.create!(job: job, depends_on_epic: upstream_epic, source: "manual")

    response = call_tool(job_id: job.id)
    payload = response_payload(response)

    expect(response[:result][:isError]).to be_falsey
    expect(payload[:job][:dependencies]).to contain_exactly(
      include(epic_id: upstream_epic.id, title: "Aqueduct surveying", state: "backlog")
    )
    expect(payload[:job][:dependencies].first).to include(:display_number)
  end

  it "includes scheduled_task_id for cron jobs" do
    task = repository.scheduled_tasks.create!(
      user: user,
      kind: "cron",
      name: "Nightly task",
      prompt: "Review the repo.",
      cron_expression: "0 3 * * *",
      pr_pileup_policy: "skip"
    )
    job = Factories.job(repository: repository, kind: "cron", issue_number: nil, scheduled_task: task)

    response = call_tool(job_id: job.id)
    payload = response_payload(response)

    expect(response[:result][:isError]).to be_falsey
    expect(payload[:job]).to include(scheduled_task_id: task.id)
  end

  it "returns all workflows in newest-first index order" do
    job = Factories.job(repository: repository)
    older = job.latest_workflow
    older.update!(created_at: 2.hours.ago)
    newer = Workflow.create!(job: job, trigger_kind: "pr_comment", created_at: 1.hour.ago)
    step = newer.steps.create!(kind: "respond", position: 0)
    step.runs.create!(job: job, trigger_kind: "pr_comment", state: "succeeded", agent_summary: "Addressed feedback.")

    response = call_tool(job_id: job.id)
    payload = response_payload(response)

    expect(payload[:workflow_count]).to eq(2)
    expect(payload[:workflows_index].map { |workflow| workflow[:id] }).to eq([ newer.id, older.id ])
    expect(payload[:workflows_index].first).to include(summary: "Addressed feedback.", started_at: nil)
  end
end
