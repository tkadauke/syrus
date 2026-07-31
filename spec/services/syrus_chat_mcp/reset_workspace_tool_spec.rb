require "rails_helper"

RSpec.describe SyrusChatMcp::ResetWorkspaceTool do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, default_branch: "main") }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository, mode: "coding") }

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
      params: { name: "reset_workspace", arguments: arguments }
    }.to_json)
    JSON.parse(raw, symbolize_names: true)
  end

  def payload(response)
    JSON.parse(response.dig(:result, :content, 0, :text), symbolize_names: true)
  end

  before { enable_coding_mode! }

  it "returns status only by default when no destructive reset is required" do
    allow(ChatWorkspace).to receive(:coding_reset_status).with(chat_session, repository).and_return(
      path: "/work/repo",
      exists: true,
      current_branch: "main",
      head_sha: "abc123",
      default_branch: "main",
      dirty: false,
      committed_ahead_count: 0,
      destructive_reset_required: false
    )
    allow(ChatWorkspace).to receive(:reset_coding_workspace!)

    response = call_tool
    body = payload(response)

    expect(response.dig(:result, :isError)).to be_falsey
    expect(body).to include(reset: false)
    expect(body[:status]).to include(current_branch: "main", committed_ahead_count: 0)
    expect(ChatWorkspace).not_to have_received(:reset_coding_workspace!)
  end

  it "refuses to discard dirty or committed-ahead work without explicit confirmation" do
    allow(ChatWorkspace).to receive(:coding_reset_status).with(chat_session, repository).and_return(
      path: "/work/repo",
      exists: true,
      current_branch: "main",
      head_sha: "abc123",
      default_branch: "main",
      dirty: true,
      committed_ahead_count: 2,
      destructive_reset_required: true
    )

    response = call_tool
    body = payload(response)

    expect(response.dig(:result, :isError)).to be(true)
    expect(body).to include(error: "confirmation_required")
    expect(body[:message]).to include("confirm_discard")
    expect(body[:status]).to include(dirty: true, committed_ahead_count: 2)
  end

  it "resets the workspace when confirm_discard is true" do
    reset_result = {
      reset: true,
      path: "/work/repo",
      before: { dirty: true, committed_ahead_count: 1, destructive_reset_required: true },
      after: { dirty: false, committed_ahead_count: 0, destructive_reset_required: false }
    }
    allow(ChatWorkspace).to receive(:reset_coding_workspace!)
      .with(chat_session, repository, confirm_discard: true)
      .and_return(reset_result)

    response = call_tool(confirm_discard: true)
    body = payload(response)

    expect(response.dig(:result, :isError)).to be_falsey
    expect(body).to include(reset: true, path: "/work/repo")
    expect(body[:message]).to include("preparation was queued")
    expect(ChatWorkspace).to have_received(:reset_coding_workspace!).with(chat_session, repository, confirm_discard: true)
  end

  it "accepts an explicit accessible repository_id" do
    other_repo = Factories.repository(user: user, default_branch: "trunk")
    allow(ChatWorkspace).to receive(:coding_reset_status).with(chat_session, other_repo).and_return(
      path: "/work/other",
      exists: true,
      current_branch: "trunk",
      default_branch: "trunk",
      dirty: false,
      committed_ahead_count: 0,
      destructive_reset_required: false
    )

    response = call_tool(repository_id: other_repo.id)
    body = payload(response)

    expect(response.dig(:result, :isError)).to be_falsey
    expect(body[:status]).to include(current_branch: "trunk")
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
end
