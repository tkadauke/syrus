require "rails_helper"

RSpec.describe Mcp::Tools::CancelCodingCheckoutTool do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, default_branch: "main") }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository, mode: "coding", coding_checkout_branch: "syrus/job-42") }

  def enable_coding_mode!(enabled: true)
    feature = Feature.find_or_create_by!(slug: "coding_mode") do |record|
      record.category = "Labs"
      record.name = "Coding Mode"
    end
    feature.update!(enabled: enabled)
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
      params: { name: "cancel_coding_checkout", arguments: arguments }
    }.to_json)
    JSON.parse(raw, symbolize_names: true)
  end

  def payload(response)
    JSON.parse(response.dig(:result, :content, 0, :text), symbolize_names: true)
  end

  before { enable_coding_mode! }

  it "cancels the active checkout and returns structured before and after status" do
    job = Factories.job_record(
      user: user,
      repository: repository,
      state: "coding",
      branch_name: "syrus/job-42",
      linked_chat_id: chat_session.id
    )
    before_status = {
      configured_branch: "syrus/job-42",
      linked_coding_job: { id: job.id, slug: job.slug, state: "coding" },
      valid_next_handoff_lanes: [ "complete_implement_step" ]
    }
    after_status = {
      configured_branch: nil,
      linked_coding_job: nil,
      valid_next_handoff_lanes: [ "submit_coding_changes" ]
    }

    allow(ChatWorkspace).to receive(:coding_reset_status)
      .with(chat_session, repository)
      .and_return(before_status, after_status)
    allow(JobCodingMode::CancelTakeover).to receive(:call)
      .with(chat_session: chat_session, repository: repository)
      .and_return(JobCodingMode::CancelTakeover::Result.new(job: job, chat_session: chat_session))

    response = call_tool
    body = payload(response)

    expect(response.dig(:result, :isError)).to be_falsey
    expect(body).to include(canceled: true, repository_id: repository.id, repository_slug: repository.slug)
    expect(body[:released_job]).to include(id: job.id, slug: job.slug, state: "coding", branch_name: "syrus/job-42")
    expect(body[:before]).to eq(before_status)
    expect(body[:after]).to eq(after_status)
    expect(body[:message]).to include("No code changes were preserved or applied")
    expect(JobCodingMode::CancelTakeover).to have_received(:call).with(chat_session: chat_session, repository: repository)
    expect(ChatWorkspace).to have_received(:coding_reset_status).with(chat_session, repository).twice
  end

  it "accepts an explicit accessible repository_id" do
    other_repo = Factories.repository(user: user)
    allow(ChatWorkspace).to receive(:coding_reset_status).and_return({})
    allow(JobCodingMode::CancelTakeover).to receive(:call)
      .with(chat_session: chat_session, repository: other_repo)
      .and_return(JobCodingMode::CancelTakeover::Result.new(job: nil, chat_session: chat_session))

    response = call_tool(repository_id: other_repo.id)

    expect(response.dig(:result, :isError)).to be_falsey
    expect(JobCodingMode::CancelTakeover).to have_received(:call).with(chat_session: chat_session, repository: other_repo)
  end

  it "returns an error when coding mode is disabled" do
    enable_coding_mode!(enabled: false)

    response = call_tool

    expect(response.dig(:result, :isError)).to be(true)
    expect(response.dig(:result, :content, 0, :text)).to include("not enabled")
  end

  it "returns an error when the repository is inaccessible" do
    response = call_tool(repository_id: 999_999_999)

    expect(response.dig(:result, :isError)).to be(true)
    expect(response.dig(:result, :content, 0, :text)).to include("not found")
  end

  it "returns service errors without pretending to preserve local work" do
    allow(ChatWorkspace).to receive(:coding_reset_status).and_return({})
    allow(JobCodingMode::CancelTakeover).to receive(:call)
      .and_raise(JobCodingMode::CancelTakeover::Error, "No active coding checkout for this chat.")

    response = call_tool

    expect(response.dig(:result, :isError)).to be(true)
    expect(response.dig(:result, :content, 0, :text)).to include("No active coding checkout")
  end
end
