require "rails_helper"

RSpec.describe Mcp::Tools::RuntimeStatusTool do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository, mode: "coding") }

  before { enable_coding_mode! }

  def call(server_context: { chat_session: chat_session }, **arguments)
    described_class.call(server_context: server_context, **arguments)
  end

  def payload(response)
    JSON.parse(response.content.first[:text], symbolize_names: true)
  end

  it "reports the chat's primary active session by default" do
    RuntimeSession.create!(repository: repository, chat_session: chat_session, workspace_ref: "a", provider_key: "browser", display_name: "Browser", state: "stopped")
    primary = RuntimeSession.create!(repository: repository, chat_session: chat_session, workspace_ref: "b", provider_key: "browser", display_name: "Browser", state: "running", primary: true)

    body = payload(call)

    expect(body[:id]).to eq(primary.id)
    expect(body[:state]).to eq("running")
  end

  it "reports an explicit session_id" do
    session = RuntimeSession.create!(repository: repository, chat_session: chat_session, workspace_ref: "a", provider_key: "browser", display_name: "Browser", state: "running")

    body = payload(call(session_id: session.id))

    expect(body[:id]).to eq(session.id)
  end

  it "includes the active agent input lease" do
    session = RuntimeSession.create!(repository: repository, chat_session: chat_session, workspace_ref: "a", provider_key: "browser", display_name: "Browser", state: "running")
    lease = RuntimeControlLease.acquire!(runtime_session: session, owner: "agent", mode: "input", reason: "testing")

    body = payload(call(session_id: session.id))

    expect(body[:active_agent_input_lease]).to include(id: lease.id, owner: "agent", mode: "input", state: "active")
  end

  it "returns nil for the lease when none is active" do
    session = RuntimeSession.create!(repository: repository, chat_session: chat_session, workspace_ref: "a", provider_key: "browser", display_name: "Browser", state: "running")

    expect(payload(call(session_id: session.id))[:active_agent_input_lease]).to be_nil
  end

  it "returns an error when there is no active session" do
    response = call

    expect(response).to be_error
    expect(response.content.first[:text]).to include("call runtime_start first")
  end

  it "returns an error for an unknown session_id" do
    response = call(session_id: 999_999_999)

    expect(response).to be_error
    expect(response.content.first[:text]).to include("not found")
  end
end
