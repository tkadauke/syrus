require "rails_helper"
RSpec.describe Coworkers::UnsavedWorkspace do
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }
  let(:coworker) { Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya-unsaved", workspace_repo: repository.remote_url) }
  let(:chat) { ChatSession.create!(user: owner, repository:, title: "Maya") }
  let!(:link) { Coworkers::Chat.create!(coworker:, chat_session: chat, role: "main") }
  let(:sleeper) { class_double(Kernel, sleep: nil) }
  let(:service) { described_class.new(chat, sleeper:) }
  let(:transient_error) { GitRunner::GitError.new([ "push" ], 1, "remote: Internal Server Error") }
  def attempt(&block) = service.attempt(branch: "coworkers/chat/1-2", path: "/tmp/preserved", operation: "chat_branch", &block)

  it "retries transient failure and clears state after success" do
    calls = 0
    expect(attempt { calls += 1; raise transient_error if calls == 1; :merged }).to eq(:merged)
    expect(link.reload).not_to be_unsaved_workspace
  end
  it "does not promise automatic retry for permanent failures" do
    allow(Coworkers::WorkspaceSaveRetryJob).to receive(:set)
    expect(attempt { raise GitRunner::GitError.new([ "push" ], 1, "Authentication failed") }).to eq(:unsaved)
    expect(Coworkers::WorkspaceSaveRetryJob).not_to have_received(:set)
    expect(chat.messages.last.content.fetch("text")).to include("needs your attention")
  end
  it "preserves state on conflict" do
    link.update!(unsaved_workspace_branch: "coworkers/chat/1-2", unsaved_workspace_operation: "chat_branch")
    expect(attempt { :conflict }).to eq(:conflict)
    expect(link.reload).to be_unsaved_workspace
    expect(chat.messages).to be_empty
  end
  it "invalidates a delayed retry when manual retry replaces it" do
    link.update!(unsaved_workspace_branch: "coworkers/chat/1-2", unsaved_workspace_operation: "chat_branch",
      unsaved_workspace_retry_scheduled_at: Time.current, unsaved_workspace_retry_token: "old-token")
    expect { service.schedule_manual_retry! }.to have_enqueued_job(Coworkers::WorkspaceSaveRetryJob)
    expect(service.begin_retry!("old-token")).to be(false)
  end
  it "deduplicates scheduled retries and updates one notice" do
    allow(Coworkers::WorkspaceSaveRetryJob).to receive_message_chain(:set, :perform_later)
    2.times { attempt { raise transient_error } }
    expect(link.reload.unsaved_workspace_attempt_count).to eq(6)
    expect(chat.messages.count).to eq(1)
    expect(Coworkers::WorkspaceSaveRetryJob).to have_received(:set).once
  end

  it "stops transient retries at the durable cap" do
    link.update!(unsaved_workspace_attempt_count: described_class::RETRY_CAP - 1)
    allow(Coworkers::WorkspaceSaveRetryJob).to receive(:set)
    expect(attempt { raise transient_error }).to eq(:unsaved)
    expect(link.reload.unsaved_workspace_attempt_count).to eq(described_class::RETRY_CAP)
    expect(link.unsaved_workspace_retry_exhausted_at).to be_present
    expect(sleeper).not_to have_received(:sleep)
    expect(Coworkers::WorkspaceSaveRetryJob).not_to have_received(:set)
  end
end
