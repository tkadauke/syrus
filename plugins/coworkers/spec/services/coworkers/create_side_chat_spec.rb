require "rails_helper"

RSpec.describe Coworkers::CreateSideChat do
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
