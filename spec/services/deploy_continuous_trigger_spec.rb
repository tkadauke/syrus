require "rails_helper"

RSpec.describe DeployContinuousTrigger do
  include ActiveJob::TestHelper

  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repo) { Factories.repository(user: user, default_branch: "main") }
  let(:client) { instance_double(GithubClient) }

  # `.syrus.yml` is read through GitHub (App::DeployAvailability ->
  # RepoDefaultBranchSyrusYml) rather than the repository's local bare
  # clone -- see "Deploy target" in CLAUDE.md ("Web pods don't need this
  # volume"). No $SYRUS_DATA_ROOT clone is created anywhere in this spec.
  # `GithubClient.for` is stubbed at the class level (rather than injecting
  # a `client:` seam, which DeployContinuousTrigger/DeployAvailability don't
  # expose here) with `is_a?(GithubClient)` stubbed true, since
  # RepoDefaultBranchSyrusYml gates the fetched client on that check and an
  # `instance_double` otherwise fails it.
  before do
    allow(GithubClient).to receive(:for).and_return(client)
    allow(client).to receive(:is_a?).with(GithubClient).and_return(true)
  end

  def stub_syrus_yml(content)
    result = content ? { content: content, size: content.bytesize } : nil
    allow(client).to receive(:file_content_at)
      .with(repo.slug, SyrusYml::CONFIG_FILE, repo.default_branch)
      .and_return(result)
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
