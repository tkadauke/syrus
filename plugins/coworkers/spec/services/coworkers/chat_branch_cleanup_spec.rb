require "rails_helper"

RSpec.describe Coworkers::ChatBranchCleanup do
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }
  let(:coworker) { Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya-clean", workspace_repo: repository.remote_url) }
  let(:chat) { ChatSession.create!(user: owner) }
  let(:link) { Coworkers::Chat.create!(coworker:, chat_session: chat, role: "main") }
  let(:branch) { "coworkers/chat/#{coworker.id}-#{chat.id}" }
  let(:remote) { instance_double(Coworkers::RemoteWorkspace, branch_sha: "a" * 40) }

  it "compare-and-deletes the chat branch" do
    allow(remote).to receive(:guarded_delete_if_matches!)

    expect(described_class.call(link, remote:)).to eq(:deleted)
    expect(remote).to have_received(:guarded_delete_if_matches!).with(branch, expected_sha: "a" * 40,
      guard: an_instance_of(Coworkers::PushGuard))
  end

  it "retains a chat branch with an unresolved conflict" do
    Coworkers::WorkspaceConflict.create!(chat_session: chat, repository:, source_branch: branch,
      files: [ "notes.md" ], versions: { "notes.md" => "conflict" }, expires_at: 1.hour.from_now)

    expect(described_class.call(link, remote:)).to eq(:retained)
    expect(remote).not_to have_received(:branch_sha)
  end

  it "retains a chat branch carrying an unsaved workspace" do
    link.update!(unsaved_workspace_branch: branch, unsaved_workspace_path: "/tmp/recovery",
      unsaved_workspace_operation: "chat_branch", unsaved_workspace_attempt_count: 1)

    expect(described_class.call(link, remote:)).to eq(:retained)
    expect(remote).not_to have_received(:branch_sha)
  end
end
