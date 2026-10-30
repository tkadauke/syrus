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
    allow(git).to receive(:run).with("rev-list", "--count", "origin/coworkers/maya..HEAD", chdir: path.to_s).and_return("1\n")

    described_class.new(chat, coworker, git: git).persist!

    expect(git).to have_received(:configure_author).with(instance_of(Coworkers::GitIdentity), chdir: path.to_s)
    expect(git).to have_received(:run).with("add", "--all", chdir: path.to_s)
    expect(git).to have_received(:run).with("commit", "-m", "Update @maya's workspace", "--no-verify", chdir: path.to_s)
    expect(git).to have_received(:run).with(
      "push", "https://token@example.test/workspace.git", "HEAD:refs/heads/coworkers/maya",
      chdir: path.to_s, env: { "GIT_TERMINAL_PROMPT" => "0" }
    )
  end

  it "does nothing when the workspace is clean and has no unpublished commits" do
    allow(ChatWorkspace).to receive(:uncommitted_changes?).with(path).and_return(false)
    allow(git).to receive(:run).with("rev-list", "--count", "origin/coworkers/maya..HEAD", chdir: path.to_s).and_return("0\n")
    described_class.new(chat, coworker, git: git).persist!
    expect(git).not_to have_received(:run).with("push", anything, anything, anything)
  end

  it "retries a previously failed push when the tree is clean but still ahead" do
    allow(ChatWorkspace).to receive(:uncommitted_changes?).with(path).and_return(false)
    allow(git).to receive(:run).with("rev-list", "--count", "origin/coworkers/maya..HEAD", chdir: path.to_s).and_return("1\n")
    push_error = GitRunner::GitError.new([ "push" ], 1, "fatal: network unavailable")
    push_attempts = 0
    allow(git).to receive(:run)
      .with("push", "https://token@example.test/workspace.git", "HEAD:refs/heads/coworkers/maya", chdir: path.to_s, env: { "GIT_TERMINAL_PROMPT" => "0" }) do
        push_attempts += 1
        raise push_error if push_attempts == 1

        ""
      end

    expect { described_class.new(chat, coworker, git: git).persist! }.to raise_error(push_error)
    expect { described_class.new(chat, coworker, git: git).persist! }.not_to raise_error
  end

  it "rebases a clean unpublished commit after a non-fast-forward push and retries" do
    allow(ChatWorkspace).to receive(:uncommitted_changes?).with(path).and_return(false)
    allow(git).to receive(:run).with("rev-list", "--count", "origin/coworkers/maya..HEAD", chdir: path.to_s).and_return("1\n")
    rejected = GitRunner::GitError.new([ "push" ], 1, "! [rejected] HEAD -> coworkers/maya (non-fast-forward)")
    push_attempts = 0
    allow(git).to receive(:run)
      .with("push", "https://token@example.test/workspace.git", "HEAD:refs/heads/coworkers/maya", chdir: path.to_s, env: { "GIT_TERMINAL_PROMPT" => "0" }) do
        push_attempts += 1
        raise rejected if push_attempts == 1

        ""
      end

    described_class.new(chat, coworker, git: git).persist!

    expect(git).to have_received(:run).with(
      "fetch", "https://token@example.test/workspace.git",
      "+refs/heads/coworkers/maya:refs/remotes/origin/coworkers/maya", "--prune",
      chdir: path.to_s, env: { "GIT_TERMINAL_PROMPT" => "0" }
    ).twice
    expect(git).to have_received(:run).with("rebase", "origin/coworkers/maya", chdir: path.to_s)
  end

  it "preserves a conflicting rebase and reports the files that need edits" do
    allow(ChatWorkspace).to receive(:uncommitted_changes?).with(path).and_return(false)
    allow(git).to receive(:run).with("rev-list", "--count", "origin/coworkers/maya..HEAD", chdir: path.to_s).and_return("1\n")
    rejected = GitRunner::GitError.new([ "push" ], 1, "rejected (fetch first)")
    conflict = GitRunner::GitError.new([ "rebase" ], 1, "CONFLICT (content): Merge conflict in SOUL.md")
    allow(git).to receive(:run)
      .with("push", "https://token@example.test/workspace.git", "HEAD:refs/heads/coworkers/maya", chdir: path.to_s, env: { "GIT_TERMINAL_PROMPT" => "0" })
      .and_raise(rejected)
    allow(git).to receive(:run).with("rebase", "origin/coworkers/maya", chdir: path.to_s).and_raise(conflict)
    allow(git).to receive(:run).with("diff", "--name-only", "--diff-filter=U", chdir: path.to_s).and_return("SOUL.md\n")

    expect { described_class.new(chat, coworker, git: git).persist! }
      .to raise_error(described_class::Conflict, /conflicts remain in SOUL\.md.*next turn.*preserved local commits/m)
    expect(git).not_to have_received(:run).with("rebase", "--abort", anything)
  end

  it "continues a resolved rebase and pushes without asking the coworker to run Git" do
    allow(ChatWorkspace).to receive(:rebase_in_progress?).with(path).and_return(true)
    service = described_class.new(chat, coworker, git: git)
    allow(service).to receive(:conflict_paths).with(path).and_return("SOUL.md")
    allow(service).to receive(:unresolved_conflict_markers?).with(path, "SOUL.md").and_return(false)

    service.persist!

    expect(git).to have_received(:run).with("add", "--all", chdir: path.to_s)
    expect(git).to have_received(:run).with("rebase", "--continue", chdir: path.to_s, env: { "GIT_EDITOR" => "true" })
    expect(git).to have_received(:run).with(
      "push", "https://token@example.test/workspace.git", "HEAD:refs/heads/coworkers/maya",
      chdir: path.to_s, env: { "GIT_TERMINAL_PROMPT" => "0" }
    )
  end
end
