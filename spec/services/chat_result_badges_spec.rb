require "rails_helper"

RSpec.describe ChatResultBadges, :reset_plugin_registry do
  it "returns empty badge lists without an identity provider" do
    chat = ChatSession.new(id: 12)

    expect(described_class.for([ chat ])).to eq(12 => [])
  end

  it "reads batched badges from identity status contributions" do
    chats = [ ChatSession.new(id: 12), ChatSession.new(id: 13) ]
    first = Class.new do
      include Syrus::Plugin::ChatIdentityProvider
      define_singleton_method(:chat_status_contributions) do |chat_sessions:, user:|
        { chat_sessions.first.id => { badges: [ { kind: "agent", id: 7, name: "Ada" } ] } }
      end
    end
    allow(first).to receive(:chat_status_contributions).and_call_original
    Syrus::PluginRegistry.register_direct(:chat_identity_provider, first)

    expect(described_class.for(chats)).to eq(
      12 => [ { "kind" => "agent", "id" => 7, "name" => "Ada" } ],
      13 => []
    )
    expect(first).to have_received(:chat_status_contributions).once.with(chat_sessions: chats, user: Current.user)
  end
end
