require "rails_helper"

RSpec.describe App::DeployAvailability do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repo) { Factories.repository(user: user) }
  let(:client) { instance_double(GithubClient) }

  # `.syrus.yml` is read over the GitHub API (RepoDefaultBranchSyrusYml), not
  # from the repository's local bare clone -- these methods are called from
  # web-tier request paths (JobDeployController, JobDetailPayload), and web
  # pods don't mount the worker's on-disk bare clone (see "Deploy target" in
  # CLAUDE.md — "Web pods don't need this volume"). No $SYRUS_DATA_ROOT clone
  # is created anywhere in this spec, simulating that environment; the
  # `client:` seam (mirroring RepositoryFeatureRecommendations' own spec)
  # injects a double directly instead of stubbing `GithubClient.for`, since
  # `instance_double` isn't `is_a?(GithubClient)`.
  def stub_syrus_yml(content)
    result = content ? { content: content, size: content.bytesize } : nil
    allow(client).to receive(:file_content_at)
      .with(repo.slug, SyrusYml::CONFIG_FILE, repo.default_branch)
      .and_return(result)
  end

  describe ".configured?" do
    it "is true when .syrus.yml declares a deploy block" do
      stub_syrus_yml("deploy:\n  run: bin/deploy\n")

      expect(described_class.configured?(repo, client: client)).to be(true)
    end

    it "is false when .syrus.yml has no deploy block" do
      stub_syrus_yml("preview:\n  start: bin/dev\n")

      expect(described_class.configured?(repo, client: client)).to be(false)
    end

    it "is false when there is no .syrus.yml on the default branch" do
      stub_syrus_yml(nil)

      expect(described_class.configured?(repo, client: client)).to be(false)
    end

    it "is false when .syrus.yml cannot be parsed" do
      stub_syrus_yml("deploy:\n  run:\n")

      expect(described_class.configured?(repo, client: client)).to be(false)
    end
  end

  describe ".allow_unapproved?" do
    it "is true when deploy.allow_unapproved is set" do
      stub_syrus_yml("deploy:\n  run: bin/deploy\n  allow_unapproved: true\n")

      expect(described_class.allow_unapproved?(repo, client: client)).to be(true)
    end

    it "defaults to false when deploy.allow_unapproved is not set" do
      stub_syrus_yml("deploy:\n  run: bin/deploy\n")

      expect(described_class.allow_unapproved?(repo, client: client)).to be(false)
    end

    it "defaults to false when deploy is not configured at all" do
      stub_syrus_yml(nil)

      expect(described_class.allow_unapproved?(repo, client: client)).to be(false)
    end
  end

  it "falls back to the repository owner's credentials when no user is given" do
    stub_syrus_yml("deploy:\n  run: bin/deploy\n  allow_unapproved: true\n")

    expect(described_class.allow_unapproved?(repo, client: client)).to be(true)
  end
end
