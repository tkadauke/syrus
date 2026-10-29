require "rails_helper"

RSpec.describe Coworkers::ChatToolSet do
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }
  let(:chat) { ChatSession.create!(user: owner, repository: repository, title: "Maya") }

  before { PluginRecord.find_by!(name: "coworkers").update!(enabled: true) }

  it "advertises message_coworker only on the essential coworker surface" do
    expect(Syrus::PluginRegistry.providers_for(:chat_mcp_tool_set)).to include(described_class)
    expect(described_class.available_for?(chat, tier: :essential)).to be(false)
    expect(described_class.available_for_coworker?(chat, tier: :essential)).to be(true)
    expect(described_class.available_for_coworker?(chat, tier: :deferred)).to be(false)

    expect(described_class.tool_definitions(tier: :essential)).to contain_exactly(
      include(name: "message_coworker", coworker_safe: true, capability: "coworker.message", mutation: true)
    )
    expect(described_class.tool_definitions(tier: :deferred).pluck(:name)).not_to include("message_coworker")
  end

  it "dispatches message_coworker through the plugin-owned tool" do
    allow(Coworkers::MessageCoworkerTool).to receive(:call).and_return(:response)

    result = described_class.new.handle("message_coworker", { "handle" => "rin", "text" => "Hello" }, { chat_session: chat })

    expect(result).to eq(:response)
    expect(Coworkers::MessageCoworkerTool).to have_received(:call).with(
      handle: "rin", text: "Hello", server_context: { chat_session: chat }
    )
  end
end
