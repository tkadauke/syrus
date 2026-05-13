require "rails_helper"
require "tmpdir"

RSpec.describe ChatWorkspace do
  let(:bare_remote_dir) { Pathname.new(Dir.mktmpdir("syrus-chatws-bare")) }
  let(:user) { Factories.user(name: "Ada Lovelace", github_token: "ghp_test_token") }
  let(:repository) do
    Factories.repository(user: user, owner: "acme", name: "widgets", default_branch: "main")
  end

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
    it "is keyed on repository id under chats/" do
      expect(described_class.path_for(repository))
        .to eq(Pathname.new(@data_root).join("chats", repository.id.to_s))
    end
  end

  describe ".ensure!" do
    it "shallow-clones the repository on first use" do
      path = described_class.ensure!(repository)

      expect(path).to exist
      expect(path.join(".git")).to exist
      expect(`git -C #{path} rev-parse --abbrev-ref HEAD`.strip).to eq("main")
    end

    it "writes .syrus/ into the git info exclude file" do
      path = described_class.ensure!(repository)

      exclude_entries = path.join(".git", "info", "exclude").read.lines.map(&:chomp)
      expect(exclude_entries).to include(".syrus/")
    end

    it "no-ops when the workspace already exists" do
      path = described_class.ensure!(repository)
      File.write(path.join("local-note.txt"), "keep me\n")

      allow_any_instance_of(GitRunner).to receive(:run).and_raise("git should not run")

      expect { described_class.ensure!(repository) }.not_to raise_error
      expect(path.join("local-note.txt").read).to eq("keep me\n")
    end
  end

  describe ".refresh!" do
    it "fetches all remotes and prunes deleted refs" do
      path = described_class.ensure!(repository)
      git = instance_double(GitRunner)
      allow(GitRunner).to receive(:new).and_return(git)

      expect(git).to receive(:run)
        .with("fetch", "--all", "--prune", chdir: path.to_s, env: { "GIT_TERMINAL_PROMPT" => "0" })

      described_class.refresh!(repository)
    end
  end

  describe ".reset!" do
    it "removes the existing workspace and re-clones it" do
      path = described_class.ensure!(repository)
      File.write(path.join("local-note.txt"), "discard me\n")

      described_class.reset!(repository)

      expect(path).to exist
      expect(path.join(".git")).to exist
      expect(path.join("local-note.txt")).not_to exist
      expect(path.join(".git", "info", "exclude").read).to include(".syrus/")
    end
  end

  describe ".destroy!" do
    it "removes the workspace path" do
      path = described_class.ensure!(repository)

      described_class.destroy!(repository)

      expect(path).not_to exist
    end

    it "is idempotent on a missing path" do
      expect { described_class.destroy!(repository) }.not_to raise_error
    end
  end

  describe "Repository destroy callback" do
    it "removes the repository chat workspace" do
      path = described_class.ensure!(repository)

      repository.destroy!

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

  def sh(cmd)
    out, err, status = Open3.capture3(
      { "GIT_AUTHOR_NAME" => "Seed", "GIT_AUTHOR_EMAIL" => "s@e",
        "GIT_COMMITTER_NAME" => "Seed", "GIT_COMMITTER_EMAIL" => "s@e" },
      cmd
    )
    raise "shell failed: #{cmd}\n#{out}\n#{err}" unless status.success?
    out
  end
end
