require "rails_helper"

RSpec.describe Coworkers::UnsavedWorkspace do
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }
  let(:coworker) { Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya", workspace_repo: repository.remote_url) }
  let(:chat) { ChatSession.create!(user: owner, repository:, title: "Maya") }
  let!(:link) { Coworkers::Chat.create!(coworker:, chat_session: chat, role: "main") }
  let(:sleeper) { class_double(Kernel, sleep: nil) }
  let(:service) { described_class.new(chat, sleeper:) }
  let(:transient_error) { GitRunner::GitError.new([ "push" ], 1, "remote: Internal Server Error") }
  let(:permanent_error) { GitRunner::GitError.new([ "push" ], 1, "remote: Authentication failed") }

  it "retries a transient failure in the turn and clears state after success" do
    calls = 0
    outcome = service.attempt(branch: "coworkers/chat/1-2", path: "/tmp/preserved") do
      calls += 1
      raise transient_error if calls == 1
    end

    expect(outcome).to eq(:saved)
    expect(calls).to eq(2)
    expect(sleeper).to have_received(:sleep).with(0.25)
    expect(link.reload).not_to be_unsaved_workspace
    expect(chat.messages).to be_empty
  end

  it "updates one durable notice across repeated transient failures and schedules one background retry" do
    allow(Coworkers::WorkspaceSaveRetryJob).to receive_message_chain(:set, :perform_later)

    2.times do
      service.attempt(branch: "coworkers/chat/1-2", path: "/tmp/preserved") { raise transient_error }
    end

    expect(link.reload).to have_attributes(
      unsaved_workspace_branch: "coworkers/chat/1-2", unsaved_workspace_path: "/tmp/preserved",
      unsaved_workspace_failure_kind: "transient", unsaved_workspace_attempt_count: 6
    )
    expect(chat.messages.count).to eq(1)
    expect(chat.messages.first.content.dig("coworker_unsaved_workspace", "attempt_count")).to eq(6)
    expect(Coworkers::WorkspaceSaveRetryJob).to have_received(:set).once
  end

  it "posts one resolved notice when a later retry clears durable unsaved state" do
    allow(Coworkers::WorkspaceSaveRetryJob).to receive_message_chain(:set, :perform_later)
    service.attempt(branch: "coworkers/chat/1-2", path: "/tmp/preserved") { raise transient_error }

    expect(service.attempt(branch: "coworkers/chat/1-2", path: "/tmp/preserved") { :ok }).to eq(:saved)

    expect(chat.messages.count).to eq(2)
    expect(chat.messages.first.content).to include("coworker_unsaved_workspace")
    expect(chat.messages.last.content).to include("coworker_workspace_save_resolved" => true)
  end

  it "does not retry or enqueue a permanent failure" do
    allow(Coworkers::WorkspaceSaveRetryJob).to receive(:set)

    outcome = service.attempt(branch: "coworkers/chat/1-2", path: "/tmp/preserved") { raise permanent_error }

    expect(outcome).to eq(:unsaved)
    expect(sleeper).not_to have_received(:sleep)
    expect(Coworkers::WorkspaceSaveRetryJob).not_to have_received(:set)
    expect(link.reload).to have_attributes(unsaved_workspace_failure_kind: "permanent", unsaved_workspace_attempt_count: 1)
  end

  it "stops transient retries at the durable cap" do
    link.update!(unsaved_workspace_attempt_count: described_class::RETRY_CAP - 1)
    allow(Coworkers::WorkspaceSaveRetryJob).to receive(:set)

    service.attempt(branch: "coworkers/chat/1-2", path: "/tmp/preserved") { raise transient_error }

    expect(link.reload.unsaved_workspace_attempt_count).to eq(described_class::RETRY_CAP)
    expect(link.unsaved_workspace_retry_exhausted_at).to be_present
    expect(sleeper).not_to have_received(:sleep)
    expect(Coworkers::WorkspaceSaveRetryJob).not_to have_received(:set)
  end
end
