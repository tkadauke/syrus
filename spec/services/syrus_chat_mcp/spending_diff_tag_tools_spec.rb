require "rails_helper"

RSpec.describe "SyrusChatMcp spending, diff, and tag tools" do
  include ActiveSupport::Testing::TimeHelpers

  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  def server
    MCP::Server.new(
      name: "syrus-chat-sidecar",
      tools: [
        SyrusChatMcp::GetSpendingTool,
        SyrusChatMcp::GetJobDiffTool,
        SyrusChatMcp::ListTagsTool,
        SyrusChatMcp::CreateTagTool,
        SyrusChatMcp::AddJobTagTool,
        SyrusChatMcp::RemoveJobTagTool
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

  def set_run_usage(run, cost, input_tokens:, output_tokens:, created_at:)
    run.update_columns(
      cost_usd: cost,
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      created_at: created_at,
      updated_at: created_at
    )
  end

  it "returns spending scoped to the current user and respects window and repository filters" do
    travel_to Time.zone.parse("2026-06-24 12:00:00") do
      mine = Factories.job(repository: repository, issue_number: 101, issue_title: "Mine")
      older = Factories.job(repository: repository, issue_number: 102, issue_title: "Older")
      other_repo = Factories.repository(user: user, owner: "acme", name: "other")
      other_repo_job = Factories.job(repository: other_repo, issue_number: 103, issue_title: "Other repo")
      other_user_job = Factories.job(repository: Factories.repository(user: Factories.user), issue_number: 104, issue_title: "Not mine")

      set_run_usage(mine.initial_run, 1.25, input_tokens: 100, output_tokens: 20, created_at: Time.zone.parse("2026-06-23 12:00:00"))
      set_run_usage(older.initial_run, 8.00, input_tokens: 800, output_tokens: 80, created_at: Time.zone.parse("2026-05-01 12:00:00"))
      set_run_usage(other_repo_job.initial_run, 2.50, input_tokens: 200, output_tokens: 40, created_at: Time.zone.parse("2026-06-23 12:00:00"))
      set_run_usage(other_user_job.initial_run, 9.99, input_tokens: 900, output_tokens: 90, created_at: Time.zone.parse("2026-06-23 12:00:00"))

      response = call_tool("get_spending", window: "7d", repository_id: repository.id)
      body = payload(response)

      expect(response.dig(:result, :isError)).to be_falsey
      expect(body).to include(total_cost_usd: 1.25, total_input_tokens: 100, total_output_tokens: 20)
      expect(body[:top_runs]).to contain_exactly(job_id: mine.id, title: "Mine", cost_usd: 1.25)
      expect(body[:by_day].size).to eq(7)
      expect(body[:by_day].select { |point| point[:cost_usd].positive? }).to eq([
        { date: "2026-06-23", cost_usd: 1.25 }
      ])
    end
  end

  it "returns zero spending when no runs exist" do
    travel_to Time.zone.parse("2026-06-24 12:00:00") do
      response = call_tool("get_spending")
      body = payload(response)

      expect(body[:total_cost_usd]).to eq(0.0)
      expect(body[:total_input_tokens]).to eq(0)
      expect(body[:total_output_tokens]).to eq(0)
      expect(body[:top_runs]).to eq([])
      expect(body[:by_day].size).to eq(30)
    end
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
