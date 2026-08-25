require "rails_helper"
require "tmpdir"
require "fileutils"

RSpec.describe App::DeployAvailability do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user) }

  around do |example|
    @data_root = Pathname.new(Dir.mktmpdir("syrus-data"))
    previous_root = ENV["SYRUS_DATA_ROOT"]
    ENV["SYRUS_DATA_ROOT"] = @data_root.to_s
    example.run
    ENV["SYRUS_DATA_ROOT"] = previous_root
    FileUtils.rm_rf(@data_root)
  end

  def write_bare_clone(repository, syrus_yml: nil)
    work_dir = Dir.mktmpdir("syrus-work")
    system("git", "init", "-q", "-b", "main", work_dir, exception: true)
    system("git", "-C", work_dir, "config", "user.email", "test@example.com", exception: true)
    system("git", "-C", work_dir, "config", "user.name", "Test", exception: true)
    File.write(File.join(work_dir, "README.md"), "hi") unless syrus_yml
    File.write(File.join(work_dir, ".syrus.yml"), syrus_yml) if syrus_yml
    system("git", "-C", work_dir, "add", ".", exception: true)
    system("git", "-C", work_dir, "commit", "-q", "-m", "init", exception: true)

    clone_path = @data_root.join("clones", "#{repository.id}.git")
    FileUtils.mkdir_p(clone_path.dirname)
    system("git", "clone", "-q", "--bare", work_dir, clone_path.to_s, exception: true)
  ensure
    FileUtils.rm_rf(work_dir) if work_dir
  end

  describe ".configured?" do
    it "is true when .syrus.yml declares a deploy block" do
      write_bare_clone(repo, syrus_yml: "deploy:\n  run: bin/deploy\n")

      expect(described_class.configured?(repo)).to be(true)
    end

    it "is false when .syrus.yml has no deploy block" do
      write_bare_clone(repo)

      expect(described_class.configured?(repo)).to be(false)
    end

    it "is false when there is no local bare clone yet" do
      expect(described_class.configured?(repo)).to be(false)
    end

    it "is false when .syrus.yml cannot be parsed" do
      write_bare_clone(repo, syrus_yml: "deploy:\n  run:\n")

      expect(described_class.configured?(repo)).to be(false)
    end
  end

  describe ".allow_unapproved?" do
    it "is true when deploy.allow_unapproved is set" do
      write_bare_clone(repo, syrus_yml: "deploy:\n  run: bin/deploy\n  allow_unapproved: true\n")

      expect(described_class.allow_unapproved?(repo)).to be(true)
    end

    it "defaults to false when deploy.allow_unapproved is not set" do
      write_bare_clone(repo, syrus_yml: "deploy:\n  run: bin/deploy\n")

      expect(described_class.allow_unapproved?(repo)).to be(false)
    end

    it "defaults to false when deploy is not configured at all" do
      write_bare_clone(repo)

      expect(described_class.allow_unapproved?(repo)).to be(false)
    end
  end
end
