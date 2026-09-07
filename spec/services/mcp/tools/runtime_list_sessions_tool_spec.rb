require "rails_helper"

RSpec.describe Mcp::Tools::RuntimeListSessionsTool do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository, mode: "coding") }

  before { enable_coding_mode! }

  def call(server_context: { chat_session: chat_session })
    described_class.call(server_context: server_context)
  end

  def payload(response)
    JSON.parse(response.content.first[:text], symbolize_names: true)
  end

  it "lists runtime sessions for the chat, most recently created last" do
    older = RuntimeSession.create!(repository: repository, chat_session: chat_session, workspace_ref: "a", provider_key: "browser", display_name: "Browser", state: "stopped")
    newer = RuntimeSession.create!(repository: repository, chat_session: chat_session, workspace_ref: "b", provider_key: "browser", display_name: "Browser", state: "running", primary: true)

    body = payload(call)

    expect(body[:sessions].map { |s| s[:id] }).to eq([ older.id, newer.id ])
    expect(body[:sessions].last).to include(state: "running", primary: true, provider_key: "browser")
  end

  it "returns an empty list when the chat has no runtime sessions" do
    expect(payload(call)).to eq(sessions: [])
  end

  it "does not include another chat's runtime sessions" do
    other_chat = ChatSession.create!(user: user, repository: repository, mode: "coding")
    RuntimeSession.create!(repository: repository, chat_session: other_chat, workspace_ref: "x", provider_key: "browser", display_name: "Browser")

    expect(payload(call)[:sessions]).to eq([])
  end

  it "returns an error when Coding Mode is disabled" do
    enable_coding_mode!(enabled: false)

    response = call

    expect(response).to be_error
    expect(response.content.first[:text]).to include("not enabled")
  end

  it "returns an error for a planning chat" do
    planning_chat = ChatSession.create!(user: user, repository: repository, mode: "planning")

    response = call(server_context: { chat_session: planning_chat })

    expect(response).to be_error
    expect(response.content.first[:text]).to include("Coding Mode")
  end
end
