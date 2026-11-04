require "rails_helper"
RSpec.describe Coworkers::WorkspaceSaveRetry do
  let(:chat) { instance_double(ChatSession) }
  let(:coworker) { instance_double(Coworkers::Coworker) }
  let(:link) { instance_double(Coworkers::Chat, chat_session: chat, coworker:) }
  it "retries the recorded chat operation" do
    lifecycle = instance_double(Coworkers::ChatWorkspaceLifecycle, finalize!: :merged)
    allow(Coworkers::ChatWorkspaceLifecycle).to receive(:new).and_return(lifecycle)
    described_class.for("chat_branch").perform(link)
    expect(lifecycle).to have_received(:finalize!).with(schedule_background: false)
  end
  it "retries the recorded home operation" do
    persistence = instance_double(Coworkers::HomeBranchPersistence, persist!: :saved)
    allow(Coworkers::HomeBranchPersistence).to receive(:new).and_return(persistence)
    described_class.for("home_branch").perform(link)
    expect(persistence).to have_received(:persist!).with(schedule_background: false)
  end
end
