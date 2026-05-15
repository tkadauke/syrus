require "rails_helper"

RSpec.describe ChatAttachment do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user) }

  it "attaches and detaches a repository from a chat session" do
    attachment = described_class.create!(chat_session: chat_session, attachable: repository)

    expect(chat_session.reload.attached_repositories).to contain_exactly(repository)

    expect {
      attachment.destroy!
    }.to change { chat_session.reload.attached_repositories.count }.from(1).to(0)
  end

  it "requires attachables to belong to the chat session user" do
    other_repository = Factories.repository
    attachment = described_class.new(chat_session: chat_session, attachable: other_repository)

    expect(attachment).not_to be_valid
    expect(attachment.errors[:attachable]).to include("must belong to the chat session user")
  end

  it "does not duplicate the same attachable on one chat session" do
    described_class.create!(chat_session: chat_session, attachable: repository)
    duplicate = described_class.new(chat_session: chat_session, attachable: repository)

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:attachable_id]).to be_present
  end
end
