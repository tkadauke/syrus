require "rails_helper"

RSpec.describe Coworkers::HomeBranchPersistence do
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }
  let(:chat) { ChatSession.create!(user: owner, repository: repository) }
  let(:coworker) { Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya", workspace_repo: repository.remote_url) }
  let(:git) { instance_double(GitRunner, configure_author: nil, run: "") }
  let(:path) { Pathname("/tmp/coworker-home") }

  before do
    Coworkers::Chat.create!(chat_session: chat, coworker: coworker, role: "main")
    allow(ChatWorkspace).to receive(:repo_path_for).with(chat, repository).and_return(path)
    allow_any_instance_of(Repository).to receive(:authenticated_url).with(user: owner).and_return("https://token@example.test/workspace.git")
  end

  it "commits and pushes dirty workspace state through the orchestrator" do
    allow(ChatWorkspace).to receive(:uncommitted_changes?).with(path).and_return(true)

    described_class.new(chat, coworker, git: git).persist!

    expect(git).to have_received(:configure_author).with(instance_of(Coworkers::GitIdentity), chdir: path.to_s)
    expect(git).to have_received(:run).with("add", "--all", chdir: path.to_s)
    expect(git).to have_received(:run).with("commit", "-m", "Update @maya's workspace", "--no-verify", chdir: path.to_s)
    expect(git).to have_received(:run).with(
      "push", "https://token@example.test/workspace.git", "HEAD:refs/heads/coworkers/maya",
      chdir: path.to_s, env: { "GIT_TERMINAL_PROMPT" => "0" }
    )
  end

  it "does nothing when the workspace is clean" do
    allow(ChatWorkspace).to receive(:uncommitted_changes?).with(path).and_return(false)
    described_class.new(chat, coworker, git: git).persist!
    expect(git).not_to have_received(:run)
  end
end
