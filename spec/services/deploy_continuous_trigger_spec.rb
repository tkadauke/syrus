require "rails_helper"
require "tmpdir"
require "fileutils"

RSpec.describe DeployContinuousTrigger do
  include ActiveJob::TestHelper

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

  describe ".after_landing!" do
    it "enqueues MaybeDeployJob when deploy.mode is continuous" do
      write_bare_clone(repo, syrus_yml: "deploy:\n  run: bin/deploy\n  mode: continuous\n")

      expect { described_class.after_landing!(repo) }
        .to have_enqueued_job(MaybeDeployJob).with(repo.id)
    end

    it "does not enqueue anything for the default manual mode" do
      write_bare_clone(repo, syrus_yml: "deploy:\n  run: bin/deploy\n")

      expect { described_class.after_landing!(repo) }
        .not_to have_enqueued_job(MaybeDeployJob)
    end

    it "does not enqueue anything when deploy is not configured" do
      write_bare_clone(repo)

      expect { described_class.after_landing!(repo) }
        .not_to have_enqueued_job(MaybeDeployJob)
    end

    it "does not enqueue anything when there is no bare clone yet" do
      expect { described_class.after_landing!(repo) }
        .not_to have_enqueued_job(MaybeDeployJob)
    end

    it "is a no-op when repository is nil" do
      expect { described_class.after_landing!(nil) }
        .not_to have_enqueued_job(MaybeDeployJob)
    end
  end
end
