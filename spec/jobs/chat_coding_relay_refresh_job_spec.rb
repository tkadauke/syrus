require "rails_helper"

RSpec.describe ChatCodingRelayRefreshJob do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  it "runs on the chat queue" do
    expect(described_class.new.queue_name).to eq("chat")
  end

  it "refreshes relay credentials for the attached repository" do
    chat_session = ChatSession.create!(user: user, repository: repository)

    expect(ChatWorkspace).to receive(:refresh_relay_credentials!).with(chat_session, repository)

    described_class.perform_now(chat_session.id)
  end

  it "no-ops when the chat has no repository" do
    chat_session = ChatSession.create!(user: user)

    expect(ChatWorkspace).not_to receive(:refresh_relay_credentials!)

    described_class.perform_now(chat_session.id)
  end
end
