require "rails_helper"
require "tmpdir"
require "fileutils"

RSpec.describe RepositoryBareClone, :ci_only do
  let(:syrus_data_root) { Pathname.new(Dir.mktmpdir("syrus-data")) }
  let(:origin_dir) { Pathname.new(Dir.mktmpdir("syrus-origin")) }
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user) }

  before do
    ENV["SYRUS_DATA_ROOT"] = syrus_data_root.to_s
    init_origin(origin_dir)
    allow_any_instance_of(Repository).to receive(:authenticated_push_url).and_return("file://#{origin_dir}")
  end

  after do
    ENV.delete("SYRUS_DATA_ROOT")
    FileUtils.rm_rf(syrus_data_root)
    FileUtils.rm_rf(origin_dir)
  end

  def git(*args, chdir: origin_dir.to_s)
    output = `git -C #{chdir} #{args.join(' ')} 2>&1`
    raise "git #{args.join(' ')} failed: #{output}" unless $?.success?
    output.strip
  end

  def init_origin(path)
    FileUtils.mkdir_p(path)
    `git init -b main #{path} 2>&1`
    `git -C #{path} config user.email "test@example.com" 2>&1`
    `git -C #{path} config user.name "Test" 2>&1`
    `touch #{path}/README.md`
    `git -C #{path} add . 2>&1`
    `git -C #{path} commit -m "initial" 2>&1`
  end

  def add_commit(msg, filename: "file-#{SecureRandom.hex(4)}.txt")
    `touch #{origin_dir}/#{filename}`
    `git -C #{origin_dir} add . 2>&1`
    `git -C #{origin_dir} commit -m "#{msg}" 2>&1`
    git("rev-parse", "HEAD")
  end

  describe ".path_for" do
    it "returns a path under the data root clones directory" do
      path = described_class.path_for(repository)
      expect(path.to_s).to include("clones")
      expect(path.to_s).to include(repository.id.to_s)
    end
  end

  describe "#sync!" do
    it "clones the bare repo when the path does not exist" do
      clone = described_class.new(repository)
      clone.sync!(user: user)

      expect(clone.path).to exist
      expect(clone.path.join("HEAD")).to exist
    end

    it "fetches updates when the clone already exists" do
      clone = described_class.new(repository)
      clone.sync!(user: user)

      sha_before = add_commit("new commit after initial clone")
      clone.sync!(user: user)

      result = `git --git-dir=#{clone.path} rev-parse HEAD 2>&1`.strip
      expect(result).to eq(sha_before)
    end
  end

  describe "#commits_behind" do
    it "returns 0 when head is up-to-date with base" do
      head_sha = add_commit("base commit")
      clone = described_class.new(repository)
      clone.sync!(user: user)

      expect(clone.commits_behind(head_sha: head_sha, base_sha: head_sha)).to eq(0)
    end

    it "returns the correct count of commits head is behind base" do
      head_sha = add_commit("PR head commit")
      add_commit("base advance 1")
      add_commit("base advance 2")
      base_sha = add_commit("base advance 3")

      clone = described_class.new(repository)
      clone.sync!(user: user)

      expect(clone.commits_behind(head_sha: head_sha, base_sha: base_sha)).to eq(3)
    end

    it "returns nil when head_sha is blank" do
      clone = described_class.new(repository)
      clone.sync!(user: user)

      expect(clone.commits_behind(head_sha: "", base_sha: "abc123")).to be_nil
    end

    it "returns nil when base_sha is blank" do
      clone = described_class.new(repository)
      clone.sync!(user: user)

      expect(clone.commits_behind(head_sha: "abc123", base_sha: "")).to be_nil
    end

    it "returns nil when the SHA is not reachable in the clone" do
      clone = described_class.new(repository)
      clone.sync!(user: user)

      expect(clone.commits_behind(head_sha: "deadbeef" * 5, base_sha: "cafebabe" * 5)).to be_nil
    end
  end
end
