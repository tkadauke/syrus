require "rails_helper"

RSpec.describe Mcp::Tools::OpenInCodingModeTool do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository, mode: "coding") }

  before do
    feature = Feature.find_or_create_by!(slug: "coding_mode") do |record|
      record.category = "Labs"
      record.name = "Coding Mode"
    end
    feature.update!(enabled: true)
    allow(ChatWorkspace).to receive(:ensure_job_branch_checkout!) do |chat, _repo, branch|
      chat.update!(coding_checkout_branch: branch, coding_checkout_uncommitted: false)
    end
  end

  def server
    MCP::Server.new(
      name: "syrus-chat-sidecar",
      tools: [ described_class ],
      server_context: { chat_session: chat_session }
    )
  end

  def call_tool(**arguments)
    raw = server.handle_json({
      jsonrpc: "2.0",
      id: 1,
      method: "tools/call",
      params: { name: "open_in_coding_mode", arguments: arguments }
    }.to_json)
    JSON.parse(raw, symbolize_names: true)
  end

  def payload(response)
    JSON.parse(response.dig(:result, :content, 0, :text), symbolize_names: true)
  end

  it "takes over an implemented Job in the current coding chat" do
    job = Factories.job_record(user: user, repository: repository, state: "implemented",
                               branch_name: "syrus/job-1", pr_number: 10)

    response = call_tool(job_id: job.id)
    result = payload(response)

    expect(response.dig(:result, :isError)).to be_falsey
    expect(result).to include(job_id: job.id, job_state: "coding", branch_name: "syrus/job-1")
    expect(job.reload).to be_coding
    expect(job.linked_chat_id).to eq(chat_session.id)
    expect(chat_session.reload.coding_checkout_branch).to eq("syrus/job-1")
  end

  it "rejects takeover when repository GitHub credentials are missing" do
    user.update!(github_token: nil)
    job = Factories.job_record(user: user, repository: repository, state: "implemented",
                               branch_name: "syrus/job-1", pr_number: 10)

    response = call_tool(job_id: job.id)

    expect(response.dig(:result, :isError)).to be(true)
    expect(response.dig(:result, :content, 0, :text)).to include(JobCodingMode::Takeover::GITHUB_TOKEN_REQUIRED_MESSAGE)
    expect(job.reload).to be_implemented
  end

  it "rejects takeover when the chat already has another active coding Job" do
    active_job = Factories.job_record(user: user, repository: repository, state: "implemented",
                                      branch_name: "syrus/active", pr_number: 11)
    active_job.update_columns(state: "coding", linked_chat_id: chat_session.id)
    target = Factories.job_record(user: user, repository: repository, state: "implemented",
                                  branch_name: "syrus/target", pr_number: 12)

    response = call_tool(job_id: target.id)

    expect(response.dig(:result, :isError)).to be(true)
    expect(response.dig(:result, :content, 0, :text)).to include(active_job.slug)
    expect(target.reload).to be_implemented
  end

  it "rejects takeover when the chat already has another coding checkout" do
    chat_session.update!(coding_checkout_branch: "syrus/other")
    target = Factories.job_record(user: user, repository: repository, state: "implemented",
                                  branch_name: "syrus/target", pr_number: 12)

    response = call_tool(job_id: target.id)

    expect(response.dig(:result, :isError)).to be(true)
    expect(response.dig(:result, :content, 0, :text)).to include("active coding checkout")
    expect(target.reload).to be_implemented
  end

  it "rejects a Job already linked to a different chat" do
    other_chat = ChatSession.create!(user: user, repository: repository, mode: "coding")
    target = Factories.job_record(user: user, repository: repository, state: "implemented",
                                  branch_name: "syrus/target", pr_number: 12)
    target.update_columns(linked_chat_id: other_chat.id)

    response = call_tool(job_id: target.id)

    expect(response.dig(:result, :isError)).to be(true)
    expect(response.dig(:result, :content, 0, :text)).to include("different chat")
    expect(target.reload).to be_implemented
  end

  it "releases the Job when checkout setup fails after claiming it" do
    target = Factories.job_record(user: user, repository: repository, state: "implemented",
                                  branch_name: "syrus/target", pr_number: 12)
    allow(ChatWorkspace).to receive(:ensure_job_branch_checkout!).and_raise(StandardError, "clone failed")

    response = call_tool(job_id: target.id)

    expect(response.dig(:result, :isError)).to be(true)
    expect(response.dig(:result, :content, 0, :text)).to include("clone failed")
    expect(target.reload).to be_implemented
    expect(target.linked_chat_id).to be_nil
  end
end
