require "rails_helper"

RSpec.describe ChatTurnLifecycles, :reset_plugin_registry do
  let(:chat) { ChatSession.create!(user: Factories.user) }
  let(:message) { chat.messages.create!(role: "user", content: { "text" => "hello" }) }

  it "uses the neutral lifecycle when no plugin claims the turn" do
    lifecycle = described_class.for(chat_session: chat, user_message: message)

    expect(lifecycle.admission).to eq({})
    expect(lifecycle.context).to eq(chat)
    expect(lifecycle).not_to be_isolated_workspace
    expect(lifecycle.synchronize { :ran }).to eq(:ran)
  end

  it "selects the first applicable plugin lifecycle" do
    provider = Class.new do
      include Syrus::Plugin::ChatTurnLifecycle
      def self.applies_to?(chat_session:, **) = chat_session.title == "claimed"
      def initialize(**) = nil
    end
    Syrus::PluginRegistry.register_direct(:chat_turn_lifecycle, provider)
    chat.update!(title: "claimed")

    expect(described_class.for(chat_session: chat, user_message: message)).to be_a(provider)
  end
end
