require "rails_helper"

RSpec.describe Coworkers::WorkspaceSaveRetryJob do
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }
  let(:coworker) { Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya", workspace_repo: repository.remote_url) }
  let(:chat) { ChatSession.create!(user: owner, repository:, title: "Maya") }
  let!(:link) do
    Coworkers::Chat.create!(coworker:, chat_session: chat, role: "main", unsaved_workspace_branch: "coworkers/chat/1-2",
      unsaved_workspace_path: "/tmp/preserved", unsaved_workspace_failure_kind: "transient", unsaved_workspace_attempt_count: 3,
      unsaved_workspace_retry_scheduled_at: Time.current)
  end

  it "runs on the consumed chat queue and retries the preserved checkout" do
    lifecycle = instance_double(Coworkers::ChatWorkspaceLifecycle)
    allow(lifecycle).to receive(:finalize!) do
      link.update!(unsaved_workspace_branch: nil, unsaved_workspace_failure_kind: nil)
      :saved
    end
    allow(Coworkers::ChatWorkspaceLifecycle).to receive(:new).with(chat).and_return(lifecycle)

    described_class.perform_now(link.id)

    expect(described_class.queue_name).to eq("chat")
    expect(lifecycle).to have_received(:finalize!).with(schedule_background: false)
    expect(link.reload.unsaved_workspace_retry_scheduled_at).to be_nil
  end
end
