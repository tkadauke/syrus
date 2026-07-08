require "rails_helper"
require "tmpdir"

RSpec.describe ChatWorkspace do
  let(:bare_remote_dir) { Pathname.new(Dir.mktmpdir("syrus-chatws-bare")) }
  let(:user) { Factories.user(name: "Ada Lovelace", github_token: "ghp_test_token") }
  let(:repository) do
    Factories.repository(user: user, owner: "acme", name: "widgets", default_branch: "main")
  end
  let(:chat_session) { ChatSession.create!(user: user) }

  before do
    seed_remote(bare_remote_dir)
    allow_any_instance_of(Repository).to receive(:remote_url).and_return("file://#{bare_remote_dir}")
    allow_any_instance_of(Repository).to receive(:authenticated_push_url).and_return("file://#{bare_remote_dir}")
    @data_root = Dir.mktmpdir("syrus-chatws-data")
    ENV["SYRUS_DATA_ROOT"] = @data_root
  end

  after do
    ENV.delete("SYRUS_DATA_ROOT")
    FileUtils.rm_rf(bare_remote_dir)
    FileUtils.rm_rf(@data_root) if @data_root
  end

  describe ".path_for" do
    it "is keyed on chat session id under chat-workspaces/" do
      expect(described_class.path_for(chat_session))
        .to eq(Pathname.new(@data_root).join("chat-workspaces", chat_session.id.to_s))
    end

    it "uses the persisted workspace path once provisioned" do
      path = described_class.ensure_root!(chat_session)

      expect(chat_session.reload.workspace_path).to eq(path.to_s)
      expect(described_class.path_for(chat_session)).to eq(path)
    end
  end

  describe ".agent_home_for" do
    it "is keyed on chat id and provider, outside the chat workspace" do
      expect(described_class.agent_home_for(chat_session, "codex"))
        .to eq(Pathname.new(@data_root).join("agent_homes", "chats", chat_session.id.to_s, "codex"))
    end
  end

  describe ".attach_repository!" do
    it "shallow-clones the repository on first use" do
      path = described_class.attach_repository!(chat_session, repository)

      expect(path).to exist
      expect(path.join(".git")).to exist
      expect(path).to eq(described_class.path_for(chat_session).join("repositories", "acme", "widgets"))
      expect(`git -C #{path} rev-parse --abbrev-ref HEAD`.strip).to eq("main")
      expect(chat_session.reload.attached_repositories).to contain_exactly(repository)
    end

    it "writes .syrus/ into the git info exclude file" do
      path = described_class.attach_repository!(chat_session, repository)

      exclude_entries = path.join(".git", "info", "exclude").read.lines.map(&:chomp)
      expect(exclude_entries).to include(".syrus/")
    end

    it "fetches and fast-forwards when the repository already exists" do
      path = described_class.attach_repository!(chat_session, repository)
      add_remote_commit("second")

      described_class.attach_repository!(chat_session, repository)

      expect(path.join("README.md").read).to include("second")
      expect(chat_session.reload.repository_attachments.count).to eq(1)
    end

    it "fetches existing checkouts from an authenticated URL" do
      path = described_class.repo_path_for(chat_session, repository)
      FileUtils.mkdir_p(path.join(".git", "info"))
      allow(repository).to receive(:authenticated_push_url)
        .with("ghp_test_token")
        .and_return("https://token@example.com/acme/widgets.git")
      git = ChatWorkspaceRecordingGitRunner.new

      described_class.new(chat_session, git: git).attach_repository!(repository)

      fetch = git.commands.find { |command| command[:args].first == "fetch" }
      expect(fetch[:args]).to eq(
        [
          "fetch",
          "https://token@example.com/acme/widgets.git",
          "+refs/heads/main:refs/remotes/origin/main",
          "--prune"
        ]
      )
      expect(fetch[:args]).not_to include("origin")
    end
  end

  describe ".destroy!" do
    it "removes the workspace path" do
      path = described_class.ensure_root!(chat_session)

      described_class.destroy!(chat_session)

      expect(path).not_to exist
    end

    it "removes the per-chat agent homes alongside the workspace" do
      path = described_class.ensure_root!(chat_session)
      agent_home = described_class.agent_home_for(chat_session, "codex")
      FileUtils.mkdir_p(agent_home.to_s)
      FileUtils.touch(agent_home.join("auth.json").to_s)

      described_class.destroy!(chat_session)

      expect(path).not_to exist
      expect(described_class.agent_homes_root_for_id(chat_session.id)).not_to exist
    end

    it "is idempotent on a missing path" do
      expect { described_class.destroy!(chat_session) }.not_to raise_error
    end
  end

  describe ".remove_artifacts_for_id!" do
    it "rejects non-positive ids" do
      expect { described_class.remove_artifacts_for_id!(0) }.to raise_error(ArgumentError)
      expect { described_class.remove_artifacts_for_id!(-3) }.to raise_error(ArgumentError)
    end

    it "ignores recorded workspace paths outside SYRUS_DATA_ROOT" do
      outside = Pathname.new(Dir.mktmpdir("syrus-chatws-outside"))
      FileUtils.touch(outside.join("keep.txt").to_s)

      described_class.remove_artifacts_for_id!(chat_session.id, recorded_workspace_path: outside.to_s)

      expect(outside.join("keep.txt")).to exist
    ensure
      FileUtils.rm_rf(outside.to_s) if outside
    end

    it "never removes the data root itself when it is passed as the recorded path" do
      marker = Pathname.new(@data_root).join("marker.txt")
      FileUtils.touch(marker.to_s)

      described_class.remove_artifacts_for_id!(chat_session.id, recorded_workspace_path: @data_root)

      expect(marker).to exist
    end
  end

  describe ".prune_idle!" do
    it "removes chat workspaces idle past the retention window and clears the path" do
      path = described_class.ensure_root!(chat_session)
      chat_session.update_columns(last_message_at: 8.days.ago, updated_at: 8.days.ago)

      expect(described_class.prune_idle!(older_than: 7.days)).to eq(1)

      expect(path).not_to exist
      expect(chat_session.reload.workspace_path).to be_nil
    end

    it "prunes the per-chat agent homes alongside the idle workspace" do
      described_class.ensure_root!(chat_session)
      agent_home = described_class.agent_home_for(chat_session, "codex")
      FileUtils.mkdir_p(agent_home.to_s)
      chat_session.update_columns(last_message_at: 8.days.ago, updated_at: 8.days.ago)

      expect(described_class.prune_idle!(older_than: 7.days)).to eq(1)

      expect(described_class.agent_homes_root_for_id(chat_session.id)).not_to exist
    end

    it "leaves recently used chat workspaces alone" do
      path = described_class.ensure_root!(chat_session)
      chat_session.update_columns(last_message_at: 1.day.ago)

      expect(described_class.prune_idle!(older_than: 7.days)).to eq(0)

      expect(path).to exist
      expect(chat_session.reload.workspace_path).to eq(path.to_s)
    end
  end

  describe ".sweep_orphans!" do
    it "removes chat-workspace and agent-home directories whose ChatSession no longer exists" do
      root = Pathname.new(@data_root)
      orphan_workspace = root.join("chat-workspaces", "424242")
      orphan_home = root.join("agent_homes", "chats", "424242")
      live_workspace = root.join("chat-workspaces", chat_session.id.to_s)
      live_home = root.join("agent_homes", "chats", chat_session.id.to_s)
      [ orphan_workspace, orphan_home, live_workspace, live_home ].each { |path| FileUtils.mkdir_p(path.to_s) }

      expect(described_class.sweep_orphans!).to eq(2)

      expect(orphan_workspace).not_to exist
      expect(orphan_home).not_to exist
      expect(live_workspace).to exist
      expect(live_home).to exist
    end

    it "skips non-numeric directory names and missing roots" do
      root = Pathname.new(@data_root)
      weird = root.join("chat-workspaces", "not-a-chat-id")
      FileUtils.mkdir_p(weird.to_s)

      expect(described_class.sweep_orphans!).to eq(0)

      expect(weird).to exist
    end
  end

  describe "ChatSession destroy" do
    it "enqueues the worker-side cleanup job instead of removing the workspace inline" do
      path = described_class.ensure_root!(chat_session)
      agent_home = described_class.agent_home_for(chat_session, "codex")
      FileUtils.mkdir_p(agent_home.to_s)
      id = chat_session.id
      workspace_path = chat_session.reload.workspace_path

      expect { chat_session.destroy! }
        .to have_enqueued_job(ChatSessionCleanupJob).with(id, workspace_path).on_queue("chat")

      # The request-side destroy leaves the filesystem alone (the web pod
      # doesn't mount the workspace PVC); the enqueued job does the removal.
      expect(path).to exist

      ChatSessionCleanupJob.perform_now(id, workspace_path)

      expect(path).not_to exist
      expect(described_class.agent_homes_root_for_id(id)).not_to exist
    end
  end

  def seed_remote(bare_path)
    Dir.mktmpdir("syrus-chatws-seed") do |seed|
      sh("git init -q -b main #{seed}")
      File.write(Pathname.new(seed).join("README.md"), "# Widgets\n")
      sh("git -C #{seed} add README.md")
      sh("git -C #{seed} commit -q -m 'initial' --author='Seed <s@e>'")
      FileUtils.mkdir_p(bare_path.dirname)
      sh("git clone -q --bare #{seed} #{bare_path}")
    end
  end

  def add_remote_commit(text)
    Dir.mktmpdir("syrus-chatws-update") do |seed|
      sh("git clone -q #{bare_remote_dir} #{seed}")
      File.open(Pathname.new(seed).join("README.md"), "a") { |f| f.puts text }
      sh("git -C #{seed} add README.md")
      sh("git -C #{seed} commit -q -m 'update' --author='Seed <s@e>'")
      sh("git -C #{seed} push -q origin main")
    end
  end

  def sh(cmd)
    out, err, status = Open3.capture3(
      { "GIT_AUTHOR_NAME" => "Seed", "GIT_AUTHOR_EMAIL" => "s@e",
        "GIT_COMMITTER_NAME" => "Seed", "GIT_COMMITTER_EMAIL" => "s@e" },
      cmd
    )
    raise "shell failed: #{cmd}\n#{out}\n#{err}" unless status.success?
    out
  end

  class ChatWorkspaceRecordingGitRunner
    attr_reader :commands

    def initialize
      @commands = []
    end

    def run(*args, **kwargs)
      @commands << { args: args, kwargs: kwargs }
      ""
    end
  end
end
