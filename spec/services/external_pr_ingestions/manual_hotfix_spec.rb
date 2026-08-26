require "rails_helper"
require "ostruct"
require "tmpdir"
require "fileutils"

RSpec.describe ExternalPrIngestions::ManualHotfix do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", default_branch: "main") }
  let(:pr) do
    OpenStruct.new(
      number: 50, title: "Urgent fix",
      head: OpenStruct.new(ref: "hotfix/urgent", repo: OpenStruct.new(full_name: repository.slug)),
      base: OpenStruct.new(ref: "main", repo: OpenStruct.new(full_name: repository.slug))
    )
  end

  around do |example|
    @data_root = Pathname.new(Dir.mktmpdir("syrus-data"))
    previous_root = ENV["SYRUS_DATA_ROOT"]
    ENV["SYRUS_DATA_ROOT"] = @data_root.to_s
    example.run
    ENV["SYRUS_DATA_ROOT"] = previous_root
    FileUtils.rm_rf(@data_root)
  end

  def write_bare_clone(repo, syrus_yml: nil)
    work_dir = Dir.mktmpdir("syrus-work")
    system("git", "init", "-q", "-b", "main", work_dir, exception: true)
    system("git", "-C", work_dir, "config", "user.email", "test@example.com", exception: true)
    system("git", "-C", work_dir, "config", "user.name", "Test", exception: true)
    File.write(File.join(work_dir, "README.md"), "hi") unless syrus_yml
    File.write(File.join(work_dir, ".syrus.yml"), syrus_yml) if syrus_yml
    system("git", "-C", work_dir, "add", ".", exception: true)
    system("git", "-C", work_dir, "commit", "-q", "-m", "init", exception: true)

    clone_path = RepositoryBareClone.path_for(repo)
    FileUtils.mkdir_p(clone_path.dirname)
    system("git", "clone", "-q", "--bare", work_dir, clone_path.to_s, exception: true)
  ensure
    FileUtils.rm_rf(work_dir) if work_dir
  end

  describe "#ingest!" do
    it "creates no review Job, but dispatches hotfix-sync detection when configured" do
      write_bare_clone(repository, syrus_yml: "delivery:\n  hotfix_sync:\n    enabled: true\n")
      expect(HotfixSyncDispatcher).to receive(:call!).with(repository: repository)

      result = nil
      expect {
        result = described_class.new.ingest!(repository: repository, pr: pr, fork_pr: false)
      }.not_to change(Job, :count)

      expect(result).to be_nil
    end

    it "does not dispatch hotfix-sync when it isn't configured" do
      write_bare_clone(repository)
      expect(HotfixSyncDispatcher).not_to receive(:call!)

      described_class.new.ingest!(repository: repository, pr: pr, fork_pr: false)
    end

    it "does not dispatch a duplicate sync when one is already pending" do
      write_bare_clone(repository, syrus_yml: "delivery:\n  hotfix_sync:\n    enabled: true\n")
      allow(HotfixSyncDispatcher).to receive(:pending_for?).with(repository).and_return(true)
      expect(HotfixSyncDispatcher).not_to receive(:call!)

      described_class.new.ingest!(repository: repository, pr: pr, fork_pr: false)
    end
  end
end
