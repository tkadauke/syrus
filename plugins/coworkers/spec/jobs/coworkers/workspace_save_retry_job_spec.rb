require "rails_helper"

RSpec.describe Coworkers::WorkspaceSaveRetryJob do
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }
  let(:coworker) { Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya", workspace_repo: repository.remote_url) }
  let(:chat) { ChatSession.create!(user: owner, repository:, title: "Maya") }
  let!(:link) do
    Coworkers::Chat.create!(coworker:, chat_session: chat, role: "main", unsaved_workspace_branch: "coworkers/chat/1-2",
      unsaved_workspace_path: "/tmp/preserved", unsaved_workspace_failure_kind: "transient",
      unsaved_workspace_operation: "chat_branch", unsaved_workspace_attempt_count: 3,
      unsaved_workspace_retry_scheduled_at: Time.current, unsaved_workspace_retry_token: "current-token")
  end

  it "runs on the consumed chat queue and retries the preserved checkout" do
    strategy = instance_double(Coworkers::WorkspaceSaveRetry::ChatBranch)
    allow(strategy).to receive(:perform) do
      link.update!(unsaved_workspace_branch: nil, unsaved_workspace_failure_kind: nil)
      :saved
    end
    allow(Coworkers::WorkspaceSaveRetry).to receive(:for).with("chat_branch").and_return(strategy)

    described_class.perform_now(link.id, "current-token")

    expect(described_class.queue_name).to eq("chat")
    expect(strategy).to have_received(:perform).with(link)
    expect(link.reload.unsaved_workspace_retry_scheduled_at).to be_nil
  end

  it "ignores an invalidated delayed retry without running or rescheduling it" do
    allow(Coworkers::WorkspaceSaveRetry).to receive(:for)

    described_class.perform_now(link.id, "superseded-token")

    expect(Coworkers::WorkspaceSaveRetry).not_to have_received(:for)
    expect(link.reload.unsaved_workspace_retry_token).to eq("current-token")
  end
end
