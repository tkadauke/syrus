require "rails_helper"

RSpec.describe Coworkers::Chat do
  let(:owner) { User.create!(email_address: "owner@example.com", password: "password123") }
  let(:coworker) { Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya", workspace_repo: "git@example.com:workspaces.git") }

  def chat
    ChatSession.create!(user: owner, title: "Coworker chat")
  end

  it "allows one main chat and any number of side chats" do
    described_class.create!(coworker: coworker, chat_session: chat, role: "main")
    described_class.create!(coworker: coworker, chat_session: chat, role: "side")
    duplicate = described_class.new(coworker: coworker, chat_session: chat, role: "main")

    expect(duplicate).not_to be_valid
  end

  it "enforces one main chat at the database boundary" do
    described_class.create!(coworker: coworker, chat_session: chat, role: "main")

    expect do
      described_class.insert!({ coworker_id: coworker.id, chat_session_id: chat.id, role: "main", created_at: Time.current, updated_at: Time.current })
    end.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "enforces one coworker link per chat at the database boundary" do
    described_class.create!(coworker: coworker, chat_session: chat, role: "side")

    expect do
      described_class.insert!({ coworker_id: coworker.id, chat_session_id: described_class.first.chat_session_id, role: "side", created_at: Time.current, updated_at: Time.current })
    end.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "rejects a chat owned by someone other than the coworker's owner" do
    other_user = User.create!(email_address: "other@example.com", password: "password123")
    other_chat = ChatSession.create!(user: other_user, title: "Someone else's chat")
    link = described_class.new(coworker: coworker, chat_session: other_chat, role: "side")

    expect(link).not_to be_valid
    expect(link.errors[:chat_session]).to include("must be owned by the coworker's owner")
    expect { link.save! }.to raise_error(ActiveRecord::RecordInvalid)
  end
end
