require "rails_helper"

RSpec.describe Mcp::Tools::RuntimeStopTool do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository, mode: "coding") }
  let(:session) do
    RuntimeSession.create!(repository: repository, chat_session: chat_session, workspace_ref: "a", provider_key: "stub", display_name: "Stub", state: "running", primary: true)
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

  it "stops the session via the provider and marks it stopped" do
    session
    body = payload(call)

    expect(body[:state]).to eq("stopped")
    expect(session.reload.state).to eq("stopped")
  end

  it "records the error and returns invalid when the provider raises" do
    allow_any_instance_of(stub_runtime_provider_class).to receive(:stop_session).and_raise("cannot stop")
    session

    response = call

    expect(response).to be_error
    expect(response.content.first[:text]).to include("cannot stop")
    expect(session.reload.last_error).to include("cannot stop")
  end
end
