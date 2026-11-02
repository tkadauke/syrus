require "rails_helper"

RSpec.describe Mcp::Tools::RuntimeWaitTool do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository, mode: "coding") }

  before do
    enable_coding_mode!
    register_stub_runtime_provider!
    RuntimeSession.create!(
      repository: repository, chat_session: chat_session, workspace_ref: "workspace",
      provider_key: "stub", display_name: "Stub", state: "running", primary: true
    )
  end

  after { Syrus::PluginRegistry.reset! }

  it "delegates provider-neutral wait conditions through inspection" do
    provider = instance_double(stub_runtime_provider_class)
    allow(stub_runtime_provider_class).to receive(:new).and_return(provider)
    expect(provider).to receive(:inspect).with(
      kind_of(Integer),
      {
        wait_for_text: "Ready", after_generation: 4, wait_for_change: true,
        quiet_ms: 250, timeout_ms: 2_000
      }
    ).and_return(kind: "terminal_screen", generation: 5)

    response = described_class.call(
      text: "Ready", after_generation: 4, quiet_ms: 250, timeout_ms: 2_000,
      server_context: { chat_session: chat_session }
    )

    expect(JSON.parse(response.content.first[:text])).to include("generation" => 5)
  end
end
