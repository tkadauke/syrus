require "rails_helper"

RSpec.describe DeployContinuousTrigger do
  include ActiveJob::TestHelper

  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repo) { Factories.repository(user: user, default_branch: "main") }

  # `.syrus.yml` is read through RepositoryContent (RepoDefaultBranchSyrusYml),
  # never the repository's local bare clone -- web pods don't mount the
  # worker's on-disk clones (see "Deploy target" in CLAUDE.md). The fake
  # content provider stands in for whichever provider plugin serves the repo.
  def stub_syrus_yml(content)
    stub_repository_content(repo, files: content ? { SyrusYml::CONFIG_FILE => content } : {})
  end

  describe ".after_landing!" do
    it "enqueues MaybeDeployJob when deploy.mode is continuous" do
      stub_syrus_yml("deploy:\n  run: bin/deploy\n  mode: continuous\n")

      expect { described_class.after_landing!(repo) }
        .to have_enqueued_job(MaybeDeployJob).with(repo.id)
    end

    it "does not enqueue anything for the default manual mode" do
      stub_syrus_yml("deploy:\n  run: bin/deploy\n")

      expect { described_class.after_landing!(repo) }
        .not_to have_enqueued_job(MaybeDeployJob)
    end

    it "does not enqueue anything when deploy is not configured" do
      stub_syrus_yml(nil)

      expect { described_class.after_landing!(repo) }
        .not_to have_enqueued_job(MaybeDeployJob)
    end

    it "does not enqueue anything when there is no .syrus.yml on the default branch" do
      stub_syrus_yml(nil)

      expect { described_class.after_landing!(repo) }
        .not_to have_enqueued_job(MaybeDeployJob)
    end

    it "is a no-op when repository is nil" do
      expect { described_class.after_landing!(nil) }
        .not_to have_enqueued_job(MaybeDeployJob)
    end
  end
end
