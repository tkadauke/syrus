require "rails_helper"

RSpec.describe Mcp::Tools::ReadEpicTool do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "roads") }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  def server
    MCP::Server.new(
      name: "syrus-chat-sidecar",
      tools: [ described_class ],
      server_context: { chat_session: chat_session }
    )
  end

  def call_tool(arguments)
    raw = server.handle_json({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "read_epic", arguments: arguments } }.to_json)
    JSON.parse(raw, symbolize_names: true)
  end

  def tool_payload(response)
    JSON.parse(response.dig(:result, :content, 0, :text), symbolize_names: true)
  end

  def count_deployment_stage_status_queries
    count = 0
    callback = lambda do |_name, _started, _finished, _id, payload|
      next if payload[:name] == "SCHEMA" || payload[:cached]

      count += 1 if payload[:sql].to_s.include?("job_deployment_stage_statuses")
    end

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    count
  end

  it "reads a readable Epic and its child Jobs without requiring a chat attachment" do
    epic = Factories.epic(
      user: user,
      repository: repository,
      title: "Pave the Appian Way again",
      description: "The stones have opinions. The operator asked for fewer of them."
    )
    upstream = Factories.job_record(
      user: user,
      repository: repository,
      issue_title: "Survey the old stones",
      state: "closed"
    )
    child = Factories.job_record(
      user: user,
      repository: repository,
      epic: epic,
      issue_title: "Set the new stones",
      issue_body: "Keep the cart wheels from litigating every mile.",
      state: "queued"
    )
    JobDependency.create!(job: child, depends_on_job: upstream, source: "manual")
    JobDependency.create!(
      job: child,
      unresolved_owner: "acme",
      unresolved_repo: "roads",
      unresolved_number: 456,
      source: "parsed"
    )

    payload = tool_payload(call_tool(id: epic.id))

    expect(payload[:epic]).to include(
      id: epic.id,
      number: epic.number,
      display_number: epic.slug,
      title: "Pave the Appian Way again",
      state: epic.reload.state,
      repository: "acme/roads"
    )
    expect(payload[:epic][:description]).to include(
      text: "The stones have opinions. The operator asked for fewer of them.",
      truncated: false
    )
    expect(payload[:epic]).to include(max_commits_behind_base: nil, furthest_behind_job: nil)
    expect(payload[:child_jobs]).to contain_exactly(
      include(
        id: child.id,
        issue_title: "Set the new stones",
        commits_behind_base: nil,
        issue_body: include(text: "Keep the cart wheels from litigating every mile."),
        depends_on_jobs: [
          include(id: upstream.id, issue_title: "Survey the old stones"),
          include(pending: true, unresolved_ref: "acme/roads#456", source: "parsed")
        ]
      )
    )
  end

  it "surfaces max_commits_behind_base and identifies the furthest-behind child job" do
    epic = Factories.epic(user: user, repository: repository, title: "Build the Via Appia")
    closer = Factories.job_record(user: user, repository: repository, epic: epic, issue_title: "Survey route")
    closer.update_column(:commits_behind_base, 3)
    furthest = Factories.job_record(user: user, repository: repository, epic: epic, issue_title: "Lay stones")
    furthest.update_column(:commits_behind_base, 15)
    unknown = Factories.job_record(user: user, repository: repository, epic: epic, issue_title: "Inspect drainage")

    payload = tool_payload(call_tool(id: epic.id))

    expect(payload[:epic]).to include(
      max_commits_behind_base: 15,
      furthest_behind_job: { id: furthest.id, slug: "JOB-#{furthest.id}" }
    )
    expect(payload[:child_jobs]).to include(
      include(id: closer.id, commits_behind_base: 3),
      include(id: furthest.id, commits_behind_base: 15),
      include(id: unknown.id, commits_behind_base: nil)
    )
  end

  it "includes landed_sha and configured deployment stages on landed child jobs" do
    staging = SyrusYml::DeploymentStage.new(name: "staging", label: "Staging", tag: "staging", tag_pattern: nil)
    production = SyrusYml::DeploymentStage.new(name: "production", label: "Production", tag: "production", tag_pattern: nil)
    allow(RepoDeploymentStagesReader).to receive(:for_repository).with(repository).and_return(
      RepoDeploymentStagesReader::Result.new(stages: [ staging, production ], source: ".syrus.yml", note: nil)
    )
    epic = Factories.epic(user: user, repository: repository, title: "Build the Via Appia")
    landed = Factories.job_record(user: user, repository: repository, epic: epic, landed_sha: "merge-sha", issue_title: "Lay stones")
    pending = Factories.job_record(user: user, repository: repository, epic: epic, landed_sha: nil, issue_title: "Inspect drainage")
    reached_at = Time.zone.parse("2026-07-30T12:00:00Z")
    landed.deployment_stage_statuses.create!(stage_name: "staging", reached_at: reached_at, tag_sha: "tag-sha")

    payload = tool_payload(call_tool(id: epic.id))

    landed_payload = payload[:child_jobs].find { |job| job[:id] == landed.id }
    pending_payload = payload[:child_jobs].find { |job| job[:id] == pending.id }
    expect(landed_payload).to include(landed_sha: "merge-sha")
    expect(landed_payload[:deployment_stages]).to eq([
      { name: "staging", label: "Staging", reached: true, reached_at: reached_at.iso8601, tag_sha: "tag-sha" },
      { name: "production", label: "Production", reached: false, reached_at: nil, tag_sha: nil }
    ])
    expect(pending_payload).to include(landed_sha: nil)
    expect(pending_payload).not_to have_key(:deployment_stages)
  end

  it "omits child job deployment stages when the repository has none configured" do
    allow(RepoDeploymentStagesReader).to receive(:for_repository).with(repository).and_return(
      RepoDeploymentStagesReader::Result.new(stages: [], source: "none", note: "no deployment_stages configured")
    )
    epic = Factories.epic(user: user, repository: repository, title: "Build the Via Appia")
    child = Factories.job_record(user: user, repository: repository, epic: epic, landed_sha: "merge-sha")

    payload = tool_payload(call_tool(id: epic.id))

    expect(payload[:child_jobs].sole).to include(id: child.id, landed_sha: "merge-sha")
    expect(payload[:child_jobs].sole).not_to have_key(:deployment_stages)
  end

  it "preloads child job deployment stage statuses" do
    staging = SyrusYml::DeploymentStage.new(name: "staging", label: "Staging", tag: "staging", tag_pattern: nil)
    allow(RepoDeploymentStagesReader).to receive(:for_repository).with(repository).and_return(
      RepoDeploymentStagesReader::Result.new(stages: [ staging ], source: ".syrus.yml", note: nil)
    )
    epic = Factories.epic(user: user, repository: repository, title: "Build the Via Appia")
    first = Factories.job_record(user: user, repository: repository, epic: epic, landed_sha: "first-sha")
    second = Factories.job_record(user: user, repository: repository, epic: epic, landed_sha: "second-sha")
    first.deployment_stage_statuses.create!(stage_name: "staging", reached_at: Time.current)
    second.deployment_stage_statuses.create!(stage_name: "staging", reached_at: Time.current)

    queries = count_deployment_stage_status_queries do
      tool_payload(call_tool(id: epic.id))
    end

    expect(queries).to eq(1)
  end

  it "rejects Epics that are not readable by the chat user" do
    other_user = Factories.user
    other_repository = Factories.repository(user: other_user, owner: "other", name: "roads")
    epic = Factories.epic(user: other_user, repository: other_repository)

    response = call_tool(id: epic.id)

    expect(response.dig(:result, :isError)).to eq(true)
    expect(tool_payload(response)).to eq(error: "not_authorized")
  end

  it "allows an admin to read another user's Epic" do
    admin = Factories.user(admin: true)
    other_user = Factories.user
    other_epic = Factories.epic(
      user: other_user,
      repository: Factories.repository(user: other_user),
      title: "Admin readable"
    )
    admin_session = ChatSession.create!(user: admin)
    admin_server = MCP::Server.new(
      name: "syrus-chat-sidecar",
      tools: [ described_class ],
      server_context: { chat_session: admin_session }
    )

    raw = admin_server.handle_json({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "read_epic", arguments: { id: other_epic.id } } }.to_json)
    response = JSON.parse(raw, symbolize_names: true)

    expect(response.dig(:result, :isError)).to be_falsey
    expect(tool_payload(response)[:epic]).to include(id: other_epic.id, title: "Admin readable")
  end
end
