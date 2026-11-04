require "rails_helper"

RSpec.describe Coworkers::WorkspaceSaveRetry do
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }
  let(:coworker) { Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya", workspace_repo: repository.remote_url) }
  let(:chat) { ChatSession.create!(user: owner, repository:, title: "Maya") }
  let(:link) { Coworkers::Chat.create!(coworker:, chat_session: chat, role: "main") }

  it "retries chat-branch saves through the chat lifecycle" do
    lifecycle = instance_double(Coworkers::ChatWorkspaceLifecycle, finalize!: :saved)
    allow(Coworkers::ChatWorkspaceLifecycle).to receive(:new).with(chat).and_return(lifecycle)

    described_class.for("chat_branch").perform(link)

    expect(lifecycle).to have_received(:finalize!).with(schedule_background: false)
  end

  it "retries home-branch saves through home branch persistence" do
    persistence = instance_double(Coworkers::HomeBranchPersistence, persist!: :saved)
    allow(Coworkers::HomeBranchPersistence).to receive(:new).with(chat, coworker).and_return(persistence)

    described_class.for("home_branch").perform(link)

    expect(persistence).to have_received(:persist!).with(schedule_background: false)
  end
end
