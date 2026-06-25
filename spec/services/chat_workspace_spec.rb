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
      git = RecordingGitRunner.new

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

    it "is idempotent on a missing path" do
      expect { described_class.destroy!(chat_session) }.not_to raise_error
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

    it "leaves recently used chat workspaces alone" do
      path = described_class.ensure_root!(chat_session)
      chat_session.update_columns(last_message_at: 1.day.ago)

      expect(described_class.prune_idle!(older_than: 7.days)).to eq(0)

      expect(path).to exist
      expect(chat_session.reload.workspace_path).to eq(path.to_s)
    end
  end

  describe "ChatSession destroy callback" do
    it "removes the chat workspace" do
      path = described_class.ensure_root!(chat_session)

      chat_session.destroy!

      expect(path).not_to exist
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

  class RecordingGitRunner
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
