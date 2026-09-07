require "rails_helper"

RSpec.describe Mcp::Tools::RuntimeLaunchTool do
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

  it "delegates to the provider with the given options" do
    session
    response = call(options: { path: "/dashboard" })

    expect(response).not_to be_error
    expect(payload(response)).to eq(launched: true, options: { path: "/dashboard" })
  end

  it "defaults to the chat's primary active session" do
    session
    expect(payload(call)).to eq(launched: true, options: {})
  end

  it "returns an error when the provider raises" do
    session
    allow_any_instance_of(stub_runtime_provider_class).to receive(:launch).and_raise("no dev server running")

    response = call

    expect(response).to be_error
    expect(response.content.first[:text]).to include("no dev server running")
  end
end
