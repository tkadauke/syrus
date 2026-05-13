require "rails_helper"

RSpec.describe ChatMessage do
  let(:repo) { Factories.repository }
  let(:session) { ChatSession.create!(repository: repo, user: repo.user) }

  it "creates with valid attributes" do
    message = described_class.create!(
      chat_session: session,
      role: "tool_use",
      content: { "name" => "inspect_repo" },
      tool_name: "inspect_repo",
      tool_use_id: "toolu_123"
    )

    expect(message).to be_persisted
    expect(message.content).to eq("name" => "inspect_repo")
  end

  it "allows each transcript role" do
    described_class::ROLES.each do |role|
      message = described_class.new(chat_session: session, role: role, content: {})
      expect(message).to be_valid
    end
  end

  it "requires a chat session" do
    message = described_class.new(role: "user", content: { "text" => "Hello" })

    expect(message).not_to be_valid
    expect(message.errors[:chat_session]).to be_present
  end

  it "validates role against the chat transcript roles" do
    message = described_class.new(chat_session: session, role: "oracle", content: { "text" => "Nope" })

    expect(message).not_to be_valid
    expect(message.errors[:role]).to be_present
  end

  it "requires content" do
    message = described_class.new(chat_session: session, role: "assistant", content: nil)

    expect(message).not_to be_valid
    expect(message.errors[:content]).to be_present
  end
end
