require "rails_helper"

RSpec.describe Coworkers::CreateSideChat do
  it "keeps the coworker fallback title eligible for first-message title generation" do
    owner = Factories.user
    repository = Factories.repository(user: owner)
    coworker = Coworkers::Coworker.create!(
      owner_user: owner, name: "Maya", handle: "maya-side-title", workspace_repo: repository.remote_url
    )

    chat = described_class.call(coworker:, user: owner, repository:)

    expect(chat.title).to be_nil
    expect(chat.coworker_chat).to have_attributes(coworker: coworker, role: "side")
    expect(chat.title_auto_fallback).to be(true)
    chat.rename!("Explicit title")
    expect(chat.reload).to have_attributes(title: "Explicit title", title_auto_fallback: false)
  end

  it "rolls back the chat session when its coworker link fails" do
    owner = Factories.user
    repository = Factories.repository(user: owner)
    coworker = Coworkers::Coworker.create!(
      owner_user: owner, name: "Maya", handle: "maya-side-rollback", workspace_repo: repository.remote_url
    )
    allow(Coworkers::Chat).to receive(:create!).and_raise(ActiveRecord::RecordInvalid.new(Coworkers::Chat.new))

    original_count = ChatSession.count
    expect do
      described_class.call(coworker:, user: owner, repository:)
    end.to raise_error(ActiveRecord::RecordInvalid)
    expect(ChatSession.count).to eq(original_count)
  end
end
