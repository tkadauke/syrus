require "rails_helper"
require "tmpdir"
require "fileutils"

RSpec.describe GitHistory::CommitLog do
  let(:syrus_data_root) { Pathname.new(Dir.mktmpdir("syrus-data")) }
  let(:origin_dir) { Pathname.new(Dir.mktmpdir("syrus-origin")) }
  let(:repository) { Factories.repository(default_branch: "main") }

  before do
    ENV["SYRUS_DATA_ROOT"] = syrus_data_root.to_s
    FileUtils.mkdir_p(origin_dir)
    `git init -b main #{origin_dir} 2>&1`
    `git -C #{origin_dir} config user.email "test@example.com" 2>&1`
    `git -C #{origin_dir} config user.name "Test" 2>&1`
  end

  after do
    ENV.delete("SYRUS_DATA_ROOT")
    FileUtils.rm_rf(syrus_data_root)
    FileUtils.rm_rf(origin_dir)
  end

  def commit!(message)
    `touch #{origin_dir}/file-#{SecureRandom.hex(4)}.txt`
    `git -C #{origin_dir} add . 2>&1`
    `git -C #{origin_dir} commit -m "#{message}" 2>&1`
    `git -C #{origin_dir} rev-parse HEAD 2>&1`.strip
  end

  def bare_clone!
    path = RepositoryBareClone.path_for(repository)
    FileUtils.mkdir_p(path.dirname)
    output = `git clone --bare #{origin_dir} #{path} 2>&1`
    raise "bare clone failed: #{output}" unless $?.success?
  end

  describe "#available?" do
    it "is false when the bare clone does not exist on disk" do
      log = described_class.new(repository: repository)

      expect(log.available?).to be false
    end

    it "is true once the bare clone exists on disk" do
      commit!("initial")
      bare_clone!

      log = described_class.new(repository: repository)

      expect(log.available?).to be true
    end
  end

  describe "#fetch" do
    it "returns an empty unavailable-shaped page when there is no bare clone" do
      log = described_class.new(repository: repository)

      page = log.fetch(cursor: nil, limit: 10)

      expect(page.entries).to eq([])
      expect(page.has_more).to be false
    end

    it "returns commits newest-first with author/committer/subject parsed out" do
      sha1 = commit!("first")
      sha2 = commit!("second")
      bare_clone!

      log = described_class.new(repository: repository)
      page = log.fetch(cursor: nil, limit: 10)

      expect(page.entries.map { |e| e[:sha] }).to eq([ sha2, sha1 ])
      expect(page.entries.first[:subject]).to eq("second")
      expect(page.entries.first[:author_name]).to eq("Test")
      expect(page.entries.first[:author_email]).to eq("test@example.com")
      expect(page.entries.first[:committer_name]).to eq("Test")
      expect(page.has_more).to be false
    end

    it "paginates with has_more true when more commits remain" do
      commit!("first")
      commit!("second")
      commit!("third")
      bare_clone!

      log = described_class.new(repository: repository)
      page = log.fetch(cursor: nil, limit: 2)

      expect(page.entries.map { |e| e[:subject] }).to eq([ "third", "second" ])
      expect(page.has_more).to be true
    end

    it "continues from a cursor without repeating the cursor commit" do
      sha1 = commit!("first")
      sha2 = commit!("second")
      commit!("third")
      bare_clone!

      log = described_class.new(repository: repository)
      first_page = log.fetch(cursor: nil, limit: 2)
      cursor = first_page.entries.last[:sha]
      expect(cursor).to eq(sha2)

      second_page = log.fetch(cursor: cursor, limit: 2)

      expect(second_page.entries.map { |e| e[:sha] }).to eq([ sha1 ])
      expect(second_page.has_more).to be false
    end

    it "returns an empty page instead of raising when the cursor sha is unknown" do
      commit!("first")
      bare_clone!

      log = described_class.new(repository: repository)
      page = log.fetch(cursor: "deadbeef" * 5, limit: 10)

      expect(page.entries).to eq([])
      expect(page.has_more).to be false
    end
  end
end
