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

  it "broadcasts the updated chat header after attaching a repository" do
    allow(AppEvents).to receive(:broadcast)

    described_class.create!(chat_session: chat_session, attachable: repository)

    expect(AppEvents).to have_received(:broadcast).with(
      hash_including(
        user: user,
        resource: "chat",
        id: chat_session.id,
        changed: [ "header" ],
        payload: hash_including(
          action: "update_header",
          chat: hash_including(
            repository: {
              id: repository.id,
              slug: repository.slug
            }
          )
        )
      )
    )
  end

  describe "attaching a Job" do
    let(:job) { Factories.job_record(user: user, repository: repository) }

    it "allows the job's creator to attach it" do
      attachment = described_class.new(chat_session: chat_session, attachable: job)

      expect(attachment).to be_valid
    end

    it "allows a repository member who did not create the job" do
      member = Factories.user
      RepositoryMembership.create!(repository: repository, user: member, role: "read")
      member_chat = ChatSession.create!(user: member)

      attachment = described_class.new(chat_session: member_chat, attachable: job)

      expect(attachment).to be_valid
    end

    it "rejects a user with no access to the job's repository" do
      job # ensure the job's owner is created before the unrelated outsider,
          # since the first User created in a test example is auto-admin
      outsider_chat = ChatSession.create!(user: Factories.user)

      attachment = described_class.new(chat_session: outsider_chat, attachable: job)

      expect(attachment).not_to be_valid
      expect(attachment.errors[:attachable]).to include("must belong to the chat session user")
    end
  end

  it "broadcasts the updated chat header after detaching a repository" do
    attachment = described_class.create!(chat_session: chat_session, attachable: repository)
    allow(AppEvents).to receive(:broadcast)

    attachment.destroy!

    expect(AppEvents).to have_received(:broadcast).with(
      hash_including(
        user: user,
        resource: "chat",
        id: chat_session.id,
        changed: [ "header" ],
        payload: hash_including(
          action: "update_header",
          chat: hash_including(repository: nil)
        )
      )
    )
  end
end
