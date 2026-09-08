require "rails_helper"

RSpec.describe Mcp::Tools::RuntimeBuildOrReloadTool do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository, mode: "coding") }
  let(:session) do
    RuntimeSession.create!(repository: repository, chat_session: chat_session, workspace_ref: "a", provider_key: "stub", display_name: "Stub", state: "failed", last_error: "previous failure")
  end

  before do
    enable_coding_mode!
    register_stub_runtime_provider!
  end

  after { Syrus::PluginRegistry.reset! }

  def call(server_context: { chat_session: chat_session }, **arguments)
    described_class.call(server_context: server_context, **arguments)
  end

  def payload(response)
    JSON.parse(response.content.first[:text], symbolize_names: true)
  end

  it "delegates to the provider and marks the session running again" do
    response = call(session_id: session.id, options: { force: true })

    expect(response).not_to be_error
    expect(payload(response)).to eq(reloaded: true)
    session.reload
    expect(session.state).to eq("running")
    expect(session.last_error).to be_nil
    expect(session.metadata).to include("reloaded" => true)
  end

  it "marks the session failed with the error when the provider raises" do
    allow_any_instance_of(stub_runtime_provider_class).to receive(:build_or_reload).and_raise("dev server crashed")

    response = call(session_id: session.id)

    expect(response).to be_error
    expect(response.content.first[:text]).to include("dev server crashed")
    session.reload
    expect(session.state).to eq("failed")
    expect(session.last_error).to include("dev server crashed")
  end

  it "returns an error for an unknown session" do
    response = call(session_id: 999_999_999)

    expect(response).to be_error
  end
end
