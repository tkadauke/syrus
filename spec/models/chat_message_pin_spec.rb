require "rails_helper"

RSpec.describe ChatMessagePin do
  let(:repo) { Factories.repository }
  let(:session) { ChatSession.create!(repository: repo, user: repo.user) }
  let(:message) { session.messages.create!(role: "assistant", content: { "text" => "Discuss the aqueduct." }) }

  it "creates with valid attributes" do
    pin = described_class.create!(chat_message: message)

    expect(pin).to be_persisted
    expect(pin.chat_message).to eq(message)
  end

  it "requires a chat message" do
    pin = described_class.new

    expect(pin).not_to be_valid
    expect(pin.errors[:chat_message]).to be_present
  end

  it "can be deleted" do
    pin = described_class.create!(chat_message: message)

    expect { pin.destroy }.to change(described_class, :count).by(-1)
  end

  it "is accessible from the chat message" do
    pin = message.pins.create!

    expect(message.pins).to include(pin)
  end

  it "broadcasts an upsert_pin app event to chat participants on create" do
    allow(AppEvents).to receive(:broadcast)
    message

    expect(AppEvents).to receive(:broadcast).with(
      user: repo.user,
      type: "updated",
      resource: "chat",
      id: session.id,
      changed: [ "pins" ],
      payload: {
        action: "upsert_pin",
        pin: { id: kind_of(Integer), chat_message_id: message.id }
      }
    )

    message.pins.create!
  end

  it "broadcasts a remove_pin app event to chat participants on destroy" do
    pin = message.pins.create!
    allow(AppEvents).to receive(:broadcast)

    expect(AppEvents).to receive(:broadcast).with(
      user: repo.user,
      type: "updated",
      resource: "chat",
      id: session.id,
      changed: [ "pins" ],
      payload: {
        action: "remove_pin",
        pin: { id: pin.id, chat_message_id: message.id }
      }
    )

    pin.destroy
  end
end
