require "rails_helper"

RSpec.describe ChatShare do
  let(:owner) { Factories.user(name: "Owner") }
  let(:recipient) { Factories.user(name: "Recipient") }
  let(:outsider) { Factories.user(name: "Outsider") }
  let(:chat) { ChatSession.create!(user: owner, title: "Shared plans") }

  it "grants live read access only to the target and revokes it immediately" do
    share = described_class.create!(chat_session: chat, target: recipient, shared_by_user: owner)

    expect(recipient.accessible_chat_sessions).to contain_exactly(chat)
    expect(outsider.accessible_chat_sessions).to be_empty
    expect(owner.accessible_chat_sessions).to contain_exactly(chat)

    share.destroy!
    expect(recipient.accessible_chat_sessions).to be_empty
    expect(owner.accessible_chat_sessions).to contain_exactly(chat)
  end

  it "requires the chat owner to create the share" do
    share = described_class.new(chat_session: chat, target: recipient, shared_by_user: outsider)

    expect(share).not_to be_valid
    expect(share.errors[:shared_by_user]).to include("must own the chat")
  end

  it "removes shares when either side is deleted" do
    described_class.create!(chat_session: chat, target: recipient, shared_by_user: owner)
    recipient.destroy!
    expect(chat.chat_shares).to be_empty

    described_class.create!(chat_session: chat, target: outsider, shared_by_user: owner)
    chat.soft_delete_by!(owner)
    expect(described_class.where(chat_session: chat)).to be_empty
  end
end
