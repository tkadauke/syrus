require "rails_helper"

RSpec.describe ChatResultBadges, :reset_plugin_registry do
  it "returns empty badge lists without a decorator" do
    chat = ChatSession.new(id: 12)

    expect(described_class.for([ chat ])).to eq(12 => [])
  end

  it "gives every decorator the page once and merges its badges" do
    chats = [ ChatSession.new(id: 12), ChatSession.new(id: 13) ]
    first = Class.new do
      include Syrus::Plugin::ChatResultDecorator
      define_singleton_method(:chat_result_badges) do |chat_sessions:|
        { chat_sessions.first.id => [ { kind: "coworker", id: 7, name: "Ada" } ] }
      end
    end
    second = Class.new do
      include Syrus::Plugin::ChatResultDecorator
      define_singleton_method(:chat_result_badges) do |chat_sessions:|
        { chat_sessions.first.id.to_s => [ { kind: "team", id: 4, name: "Core" } ] }
      end
    end
    allow(first).to receive(:chat_result_badges).and_call_original
    allow(second).to receive(:chat_result_badges).and_call_original
    Syrus::PluginRegistry.register(:chat_result_decorator, first)
    Syrus::PluginRegistry.register(:chat_result_decorator, second)

    expect(described_class.for(chats)).to eq(
      12 => [ { kind: "coworker", id: 7, name: "Ada" }, { kind: "team", id: 4, name: "Core" } ],
      13 => []
    )
    expect(first).to have_received(:chat_result_badges).once.with(chat_sessions: chats)
    expect(second).to have_received(:chat_result_badges).once.with(chat_sessions: chats)
  end
end
