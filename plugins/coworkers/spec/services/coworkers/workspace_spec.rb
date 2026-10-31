require "rails_helper"

RSpec.describe Coworkers::Workspace do
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }
  let(:chat) { ChatSession.create!(user: owner, repository: repository) }
  let(:coworker) { Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya", workspace_repo: repository.remote_url) }
  let(:root) { Pathname(Dir.mktmpdir("coworker-workspace")) }
  let(:workspace) { described_class.new(chat) }

  before do
    Coworkers::Chat.create!(chat_session: chat, coworker: coworker, role: "main")
    allow(ChatWorkspace).to receive(:repo_path_for).with(chat, repository).and_return(root)
    root.join("SOUL.md").write("old soul\n")
  end

  after { FileUtils.rm_rf(root) }

  it "creates, edits, moves, and deletes files inside the coworker's workspace" do
    expect(workspace.write("memory/daily/today.md", "first\n")).to eq("memory/daily/today.md")
    expect(workspace.edit("memory/daily/today.md", "first", "second")).to eq("memory/daily/today.md")
    expect(workspace.move("memory/daily/today.md", "memory/daily/archive.md"))
      .to eq(source: "memory/daily/today.md", destination: "memory/daily/archive.md")
    expect(workspace.delete("memory/daily/archive.md")).to eq("memory/daily/archive.md")
    expect(root.join("memory/daily/archive.md")).not_to exist
  end

  it "allows identity files to be updated during an ordinary turn" do
    workspace.edit("SOUL.md", "old soul", "new soul")
    expect(root.join("SOUL.md").read).to eq("new soul\n")
  end

  it "rejects traversal, absolute paths, Git metadata, and symlink escapes" do
    outside = Pathname(Dir.mktmpdir("other-coworker"))
    outside.join("USER.md").write("private\n")
    File.symlink(outside, root.join("other"))

    expect { workspace.write("../escape.md", "bad") }.to raise_error(described_class::InvalidPath, /escapes/)
    expect { workspace.write(outside.join("escape.md").to_s, "bad") }.to raise_error(described_class::InvalidPath, /relative/)
    expect { workspace.write(".git/config", "bad") }.to raise_error(described_class::InvalidPath, /orchestrator-owned/)
    expect { workspace.write("other/USER.md", "bad") }.to raise_error(described_class::InvalidPath, /symbolic links/)
    expect(outside.join("USER.md").read).to eq("private\n")
  ensure
    FileUtils.rm_rf(outside) if outside
  end
end
