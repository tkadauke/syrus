require "rails_helper"

RSpec.describe ChatSession do
  let(:repo) { Factories.repository }

  it "creates with valid attributes and token defaults" do
    session = described_class.create!(repository: repo, user: repo.user, title: "Plan the aqueduct")

    expect(session).to be_persisted
    expect(session.cumulative_input_tokens).to eq(0)
    expect(session.cumulative_output_tokens).to eq(0)
  end

  it "requires a repository" do
    session = described_class.new(user: repo.user)

    expect(session).not_to be_valid
    expect(session.errors[:repository]).to be_present
  end

  it "requires a user" do
    session = described_class.new(repository: repo)

    expect(session).not_to be_valid
    expect(session.errors[:user]).to be_present
  end

  it "rejects negative token counts" do
    session = described_class.new(
      repository: repo,
      user: repo.user,
      cumulative_input_tokens: -1,
      cumulative_output_tokens: -1
    )

    expect(session).not_to be_valid
    expect(session.errors[:cumulative_input_tokens]).to be_present
    expect(session.errors[:cumulative_output_tokens]).to be_present
  end

  it "destroys messages with the session" do
    session = described_class.create!(repository: repo, user: repo.user)
    message = session.messages.create!(role: "user", content: { "text" => "Ave" })

    expect { session.destroy }.to change { ChatMessage.where(id: message.id).count }.by(-1)
  end

  it "reports a turn in flight until a non-user response follows the latest user message" do
    session = described_class.create!(repository: repo, user: repo.user)

    expect(session).not_to be_turn_in_flight

    session.messages.create!(role: "user", content: { "text" => "Ave" })
    expect(session).to be_turn_in_flight

    session.messages.create!(role: "assistant", content: { "text" => "Salve" })
    expect(session).not_to be_turn_in_flight
  end

  it "is destroyed with its repository" do
    session = described_class.create!(repository: repo, user: repo.user)

    expect { repo.destroy }.to change { described_class.where(id: session.id).count }.by(-1)
  end

  it "is visible from the owning user" do
    session = described_class.create!(repository: repo, user: repo.user)

    expect(repo.user.chat_sessions).to include(session)
  end
end
