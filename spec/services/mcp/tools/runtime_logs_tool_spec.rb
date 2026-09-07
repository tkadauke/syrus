require "rails_helper"

RSpec.describe Mcp::Tools::RuntimeLogsTool do
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

  it "defaults cursor to the beginning" do
    session
    expect(payload(call)).to eq(entries: [ "line-0" ], cursor: 1)
  end

  it "passes the given cursor through to the provider" do
    session
    expect(payload(call(cursor: "3"))).to eq(entries: [ "line-3" ], cursor: 4)
  end
end
