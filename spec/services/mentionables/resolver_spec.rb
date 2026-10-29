require "rails_helper"

RSpec.describe Mentionables::Resolver do
  let(:owner) { Factories.user(email_address: "owner@example.com") }
  let(:chat) { ChatSession.create!(user: owner, conversation_kind: "group") }

  it "resolves only complete, addressable handles" do
    maya = Factories.user(email_address: "maya@example.com")
    chat.chat_participants.create!(user: maya, role: "member")

    mentions = described_class.resolve(text: "Ask @maya, not @maya-team or @mayank.", chat: chat)

    expect(mentions).to eq([
      { "kind" => "human", "id" => maya.id, "handle" => "maya", "start" => 4, "end" => 9 }
    ])
  end

  it "accepts mentionables supplied by a plugin provider" do
    coworker = Struct.new(:id) do
      include Mentionable
      def handle = "maya"
      def display_name = "Maya"
      def subtitle = "Researcher"
      def kind = "coworker"
      def avatar_url = nil
      def accent_hex = "#E5484D"
      def agentic? = true
      def addressable_in?(_chat) = true
    end.new(41)
    provider = Class.new do
      include Syrus::Plugin::Mentionable
      define_singleton_method(:mentionables) { |chat:| [ coworker ] }
      define_singleton_method(:find_mentionable) { |kind:, id:| coworker if kind == "coworker" && id == 41 }
    end
    allow(Syrus::PluginRegistry).to receive(:providers_for).and_call_original
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:mentionable).and_return([ provider ])

    mention = described_class.resolve(text: "Ask @maya", chat: chat).sole

    expect(mention).to include("kind" => "coworker", "id" => 41)
    expect(described_class.find(kind: "coworker", id: 41)).to be(coworker)
  end

  it "exposes the complete core Mentionable contract" do
    syrus = Mentionables::Syrus.new

    expect(syrus).to have_attributes(
      handle: "syrus", display_name: "Syrus", subtitle: "Engineer", kind: "syrus",
      avatar_url: nil, accent_hex: "#FBCFD3", agentic?: true
    )
    expect(owner).to have_attributes(kind: "human", avatar_url: nil, accent_hex: nil, agentic?: false)
  end
end
