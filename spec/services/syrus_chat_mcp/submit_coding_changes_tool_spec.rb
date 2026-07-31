require "rails_helper"

RSpec.describe Mcp::Tools::SubmitCodingChangesTool do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  def enable_coding_mode!
    feature = Feature.find_or_create_by!(slug: "coding_mode") do |record|
      record.category = "Labs"
      record.name = "Coding Mode"
    end
    feature.update!(enabled: true)
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
      params: { name: "submit_coding_changes", arguments: arguments }
    }.to_json)
    JSON.parse(raw, symbolize_names: true)
  end

  def payload(response)
    JSON.parse(response.dig(:result, :content, 0, :text), symbolize_names: true)
  end

  before do
    enable_coding_mode!
    allow(CodingHandoffCapture).to receive(:capture!) do |chat_session:, repository:, user:, source_branch:, handoff_branch:|
      {
        "source_branch" => source_branch,
        "handoff_branch" => handoff_branch,
        "head_sha" => "abc123",
        "base_sha" => "def456",
        "default_branch" => repository.default_branch,
        "changed_files" => [ "app/frontend/App.tsx" ],
        "captured_at" => Time.current.iso8601,
        "chat_session_id" => chat_session.id
      }
    end
  end

  it "creates a pending action for the chat session's repository" do
    response = call_tool(branch: "feature/my-work", title: "Add user profile page", description: "Adds a user profile page with avatar and bio fields.")
    body = payload(response)
    pending_action = chat_session.pending_actions.find(body[:pending_action_id])

    expect(response.dig(:result, :isError)).to be_falsey
    expect(body).to include(state: "pending")
    expect(body[:message]).to include("pending operator confirmation")
    expect(body[:message]).to include("feature/my-work")
    expect(pending_action).to have_attributes(
      action: "submit_coding_changes",
      state: "pending",
      requested_by: "agent"
    )
    expect(pending_action.payload).to eq(
      "repository_id" => repository.id,
      "branch" => "feature/my-work",
      "title" => "Add user profile page",
      "description" => "Adds a user profile page with avatar and bio fields."
    )
  end

  it "stores title in the payload" do
    response = call_tool(branch: "feature/my-work", title: "Add user profile page", description: "Adds a user profile page.")
    body = payload(response)
    pending_action = chat_session.pending_actions.find(body[:pending_action_id])

    expect(response.dig(:result, :isError)).to be_falsey
    expect(pending_action.payload).to include("title" => "Add user profile page")
  end

  it "defaults branch to the active coding checkout branch" do
    allow(ChatWorkspace).to receive(:coding_checkout_snapshot)
      .with(chat_session, repository)
      .and_return(current_branch: "main")

    response = call_tool(title: "Implement feature", description: "Implements the feature.")
    body = payload(response)
    pending_action = chat_session.pending_actions.find(body[:pending_action_id])

    expect(response.dig(:result, :isError)).to be_falsey
    expect(pending_action.payload["branch"]).to eq("main")
  end

  it "accepts an explicit repository_id" do
    other_repo = Factories.repository(user: user)

    response = call_tool(
      repository_id: other_repo.id,
      branch: "feature/my-work",
      title: "Implement feature",
      description: "Implements the feature."
    )
    body = payload(response)
    pending_action = chat_session.pending_actions.find(body[:pending_action_id])

    expect(response.dig(:result, :isError)).to be_falsey
    expect(pending_action.payload["repository_id"]).to eq(other_repo.id)
  end

  it "returns an error when coding mode is disabled" do
    Feature.find_by(slug: "coding_mode")&.update!(enabled: false)

    response = call_tool(branch: "feature/my-work", title: "Implement feature", description: "Implements the feature.")

    expect(response.dig(:result, :isError)).to be(true)
    expect(response.dig(:result, :content, 0, :text)).to include("not enabled")
  end

  it "returns an error for an unknown repository_id" do
    response = call_tool(
      repository_id: 999_999_999,
      branch: "feature/my-work",
      title: "Implement feature",
      description: "Implements the feature."
    )

    expect(response.dig(:result, :isError)).to be(true)
    expect(response.dig(:result, :content, 0, :text)).to include("not found")
  end

  it "returns an error when branch is blank" do
    response = call_tool(branch: "   ", title: "Implement feature", description: "Implements the feature.")

    expect(response.dig(:result, :isError)).to be(true)
    expect(response.dig(:result, :content, 0, :text)).to include("branch")
  end

  it "returns an error when title is blank" do
    response = call_tool(branch: "feature/my-work", title: "   ", description: "Implements the feature.")

    expect(response.dig(:result, :isError)).to be(true)
    expect(response.dig(:result, :content, 0, :text)).to include("title")
  end

  it "returns an error when description is blank" do
    response = call_tool(branch: "feature/my-work", title: "Implement feature", description: "   ")

    expect(response.dig(:result, :isError)).to be(true)
    expect(response.dig(:result, :content, 0, :text)).to include("description")
  end

  it "returns an error when the chat session has no repository and none is provided" do
    no_repo_chat = ChatSession.create!(user: user)

    server_no_repo = MCP::Server.new(
      name: "syrus-chat-sidecar",
      tools: [ described_class ],
      server_context: { chat_session: no_repo_chat }
    )
    raw = server_no_repo.handle_json({
      jsonrpc: "2.0",
      id: 1,
      method: "tools/call",
      params: { name: "submit_coding_changes", arguments: { branch: "main", title: "stuff", description: "stuff" } }
    }.to_json)
    response = JSON.parse(raw, symbolize_names: true)

    expect(response.dig(:result, :isError)).to be(true)
    expect(response.dig(:result, :content, 0, :text)).to include("not found")
  end

  it "enqueues CodingHandoffConfirmJob and leaves result nil on confirmation" do
    response = call_tool(branch: "feature/my-work", title: "Implement feature", description: "Implements the feature.")
    pending_action = chat_session.pending_actions.find(payload(response)[:pending_action_id])

    expect { pending_action.confirm!(user: user) }.to have_enqueued_job(CodingHandoffConfirmJob).with(pending_action.id)
    expect(pending_action.reload).to be_confirmed
    expect(pending_action.result).to be_nil
  end
end
