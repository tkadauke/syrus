require "rails_helper"
require "tmpdir"
require "fileutils"

RSpec.describe App::PreviewAvailability do
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
    it "is true when a preview_provider plugin is registered, even without .syrus.yml" do
      allow(Syrus::Plugin::PreviewProvider).to receive(:configured?).and_return(true)

      expect(described_class.configured?(repo)).to be(true)
    end

    context "without a registered preview_provider plugin" do
      before { allow(Syrus::Plugin::PreviewProvider).to receive(:configured?).and_return(false) }

      it "is true when .syrus.yml declares a preview block" do
        write_bare_clone(repo, syrus_yml: "preview:\n  start: bin/dev\n")

        expect(described_class.configured?(repo)).to be(true)
      end

      it "is false when .syrus.yml has no preview block" do
        write_bare_clone(repo)

        expect(described_class.configured?(repo)).to be(false)
      end

      it "is false when there is no local bare clone yet" do
        expect(described_class.configured?(repo)).to be(false)
      end
    end
  end
end
