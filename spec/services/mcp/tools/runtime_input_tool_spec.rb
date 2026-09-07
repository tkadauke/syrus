require "rails_helper"

RSpec.describe Mcp::Tools::RuntimeInputTool do
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

  it "goes through the provider's lease enforcement and is rejected without a lease" do
    session
    body = payload(call(event: { type: "click" }))

    expect(body).to eq(error: "lease_required")
  end

  it "is delivered once the agent holds an active input lease" do
    session
    RuntimeControlLease.acquire!(runtime_session: session, owner: "agent", mode: "input", reason: "click a button")

    body = payload(call(event: { type: "click" }))

    expect(body).to eq(delivered: { type: "click" })
  end

  it "rejects a non-object event" do
    session
    response = call(event: "click")

    expect(response).to be_error
    expect(response.content.first[:text]).to include("event must be an object")
  end
end
