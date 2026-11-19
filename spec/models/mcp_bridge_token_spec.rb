require "rails_helper"

RSpec.describe McpBridgeToken do
  let!(:_bootstrap_admin) { Factories.user(admin: true) }
  let(:user) { Factories.user }

  it "stores only a digest and authenticates the plaintext" do
    token, plaintext = described_class.issue!(user:, name: "laptop")

    expect(token.token_digest).to eq(Digest::SHA256.hexdigest(plaintext))
    expect(token.token_prefix).to eq(plaintext.first(token.token_prefix.length))
    expect(described_class.authenticate(plaintext)).to eq(token)
    expect(described_class.authenticate(plaintext.chop)).to be_nil
  end

  it "creates its bridge chat once, and again only after the operator deleted it" do
    token, = described_class.issue!(user:, name: "laptop")

    chat = token.bridge_chat!

    expect(chat).to have_attributes(origin_platform: ChatSession::MCP_BRIDGE_PLATFORM, user: user)
    expect(chat.title).to include("laptop")
    expect(token.bridge_chat!).to eq(chat)

    chat.update!(deleted_at: Time.current)

    expect(token.bridge_chat!).not_to eq(chat)
  end

  describe "the bridge chat" do
    it "never runs a turn of Syrus's own chat agent" do
      token, = described_class.issue!(user:, name: "laptop")
      chat = token.bridge_chat!
      message = chat.messages.create!(role: "system", content: { "text" => "Pending action confirmed" }, skip_turn_trigger: true)
      allow(ChatTurnLifecycles).to receive(:for).and_call_original

      ChatTurnJob.perform_now(chat.id, message.id)

      expect(ChatTurnLifecycles).not_to have_received(:for)
      expect(chat.reload.turn_in_flight).to be(false)
    end
  end
end
