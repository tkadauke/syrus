require "rails_helper"

RSpec.describe "Mcp::Tools diff and tag tools" do
  include ActiveSupport::Testing::TimeHelpers

  let!(:_bootstrap_admin) { Factories.user(admin: true) }

  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  def server
    MCP::Server.new(
      name: "syrus-chat-sidecar",
      tools: [
        Mcp::Tools::GetJobDiffTool,
        Mcp::Tools::ListTagsTool,
        Mcp::Tools::CreateTagTool,
        Mcp::Tools::AddJobTagTool,
        Mcp::Tools::RemoveJobTagTool
      ],
      server_context: { chat_session: chat_session }
    )
  end

  def call_tool(name, arguments = {})
    raw = server.handle_json({
      jsonrpc: "2.0",
      id: 1,
      method: "tools/call",
      params: { name: name, arguments: arguments }
    }.to_json)
    JSON.parse(raw, symbolize_names: true)
  end

  def payload(response)
    JSON.parse(response.dig(:result, :content, 0, :text), symbolize_names: true)
  end

  it "returns stored job diff text in paginated 50 KB chunks" do
    job = Factories.job(repository: repository)
    run = job.latest_workflow.runs.order(:id).last
    diff = ("diff --git a/file.txt b/file.txt\n+" + ("a" * 60.kilobytes) + "é")
    run.update!(agent_diff: diff)

    response = call_tool("get_job_diff", job_id: job.id)
    body = payload(response)

    expect(response.dig(:result, :isError)).to be_falsey
    expect(body[:job_id]).to eq(job.id)
    expect(body[:run_id]).to eq(run.id)
    expect(body).to include(
      page: 1,
      per_bytes: 50.kilobytes,
      total_bytes: diff.bytesize,
      total_pages: 2,
      has_next_page: true,
      next_page: 2
    )
    expect(body[:diff].bytesize).to be <= 50.kilobytes
    expect(body[:diff]).to be_valid_encoding

    second_page = payload(call_tool("get_job_diff", job_id: job.id, page: 2))

    expect(second_page).to include(page: 2, total_pages: 2, has_next_page: false)
    expect(second_page[:diff]).to be_valid_encoding
    expect(second_page[:diff]).to include("a")
  end

  it "normalizes job diff pagination inputs" do
    job = Factories.job(repository: repository)
    run = job.latest_workflow.runs.order(:id).last
    run.update!(agent_diff: "abcdef")

    body = payload(call_tool("get_job_diff", job_id: job.id, page: 0, per_bytes: 100.kilobytes))

    expect(body).to include(page: 1, per_bytes: 50.kilobytes, total_pages: 1)
    expect(body[:diff]).to eq("abcdef")
  end

  it "returns a clear message when a job has no stored diff" do
    job = Factories.job(repository: repository)

    response = call_tool("get_job_diff", job_id: job.id)
    body = payload(response)

    expect(body).to include(
      job_id: job.id,
      diff: nil,
      total_bytes: 0,
      total_pages: 0,
      has_next_page: false,
      message: "No stored diff is available for this Job yet."
    )
  end

  it "reads a diff for a job outside the chat repository when it belongs to the chat user" do
    other = Factories.job(repository: Factories.repository(user: user))

    response = call_tool("get_job_diff", job_id: other.id)
    body = payload(response)

    expect(response.dig(:result, :isError)).to be_falsey
    expect(body).to include(job_id: other.id, diff: nil)
  end

  it "allows an admin to read another user's job diff" do
    admin = Factories.user(admin: true)
    other_job = Factories.job(repository: Factories.repository(user: Factories.user))
    admin_session = ChatSession.create!(user: admin)
    admin_server = MCP::Server.new(
      name: "syrus-chat-sidecar",
      tools: [ Mcp::Tools::GetJobDiffTool ],
      server_context: { chat_session: admin_session }
    )

    raw = admin_server.handle_json({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "get_job_diff", arguments: { job_id: other_job.id } } }.to_json)
    response = JSON.parse(raw, symbolize_names: true)

    expect(response.dig(:result, :isError)).to be_falsey
    expect(payload(response)).to include(job_id: other_job.id)
  end

  it "lists only current user's tags" do
    mine = Factories.tag(user: user, name: "urgent", color: "red")
    Factories.tag(user: Factories.user, name: "other", color: "blue")

    response = call_tool("list_tags")

    expect(payload(response)[:tags]).to contain_exactly(id: mine.id, name: "urgent", color: "red")
  end

  it "creates tags and validates blank and duplicate names" do
    response = call_tool("create_tag", name: "area:auth", color: "#123abc")
    body = payload(response)

    expect(response.dig(:result, :isError)).to be_falsey
    expect(body).to include(name: "area:auth", color: "#123abc")
    expect(user.tags.find(body[:id])).to have_attributes(name: "area:auth", color: "#123abc")

    blank = call_tool("create_tag", name: " ")
    duplicate = call_tool("create_tag", name: "area:auth")

    expect(blank.dig(:result, :isError)).to be(true)
    expect(blank.dig(:result, :content, 0, :text)).to include("Name can't be blank")
    expect(duplicate.dig(:result, :isError)).to be(true)
    expect(duplicate.dig(:result, :content, 0, :text)).to include("Name has already been taken")
  end

  it "adds and removes job tags idempotently" do
    allow(AppEvents).to receive(:broadcast)
    job = Factories.job(repository: repository)
    tag = Factories.tag(user: user)

    expect {
      2.times { call_tool("add_job_tag", job_id: job.id, tag_id: tag.id) }
    }.to change { JobTag.count }.by(1)

    expect(payload(call_tool("add_job_tag", job_id: job.id, tag_id: tag.id))).to eq(success: true)
    expect {
      2.times { call_tool("remove_job_tag", job_id: job.id, tag_id: tag.id) }
    }.to change { JobTag.count }.by(-1)
    expect(payload(call_tool("remove_job_tag", job_id: job.id, tag_id: tag.id))).to eq(success: true)
  end

  it "rejects cross-user jobs and tags when changing job tags" do
    job = Factories.job(repository: Factories.repository(user: Factories.user))
    tag = Factories.tag(user: Factories.user)

    job_response = call_tool("add_job_tag", job_id: job.id, tag_id: Factories.tag(user: user).id)
    tag_response = call_tool("add_job_tag", job_id: Factories.job(repository: repository).id, tag_id: tag.id)

    expect(job_response.dig(:result, :isError)).to be(true)
    expect(payload(job_response)).to eq(error: "not_authorized")
    expect(tag_response.dig(:result, :isError)).to be(true)
    expect(tag_response.dig(:result, :content, 0, :text)).to include("tag not found")
  end
end
