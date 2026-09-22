require "rails_helper"

RSpec.describe App::PreviewAvailability do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repo) { Factories.repository(user: user) }

  # `.syrus.yml` is read through RepositoryContent (RepoDefaultBranchSyrusYml),
  # never the repository's local bare clone -- web pods don't mount the
  # worker's on-disk clones (see "Deploy target" in CLAUDE.md). The fake
  # content provider stands in for whichever provider plugin serves the repo.
  def stub_syrus_yml(content)
    stub_repository_content(repo, files: content ? { SyrusYml::CONFIG_FILE => content } : {})
  end

  describe ".configured?" do
    it "is true when a preview_provider plugin is registered, even without .syrus.yml" do
      allow(Syrus::Plugin::PreviewProvider).to receive(:configured?).and_return(true)

      expect(described_class.configured?(repo)).to be(true)
    end

    context "without a registered preview_provider plugin" do
      before { allow(Syrus::Plugin::PreviewProvider).to receive(:configured?).and_return(false) }

      it "is true when .syrus.yml declares a preview block" do
        stub_syrus_yml("preview:\n  start: bin/dev\n")

        expect(described_class.configured?(repo)).to be(true)
      end

      it "is false when .syrus.yml has no preview block" do
        stub_syrus_yml("deploy:\n  run: bin/deploy\n")

        expect(described_class.configured?(repo)).to be(false)
      end

      it "is false when there is no .syrus.yml on the default branch" do
        stub_syrus_yml(nil)

        expect(described_class.configured?(repo)).to be(false)
      end
    end
  end
end
