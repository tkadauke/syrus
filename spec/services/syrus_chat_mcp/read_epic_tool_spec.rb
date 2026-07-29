require "rails_helper"

RSpec.describe SyrusChatMcp::ReadEpicTool do
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

  it "rejects Epics that are not readable by the chat user" do
    other_user = Factories.user
    other_repository = Factories.repository(user: other_user, owner: "other", name: "roads")
    epic = Factories.epic(user: other_user, repository: other_repository)

    response = call_tool(id: epic.id)

    expect(response.dig(:result, :isError)).to eq(true)
    expect(tool_payload(response)).to eq(error: "not_authorized")
  end
end
