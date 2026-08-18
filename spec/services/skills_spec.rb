require "rails_helper"

RSpec.describe Skills do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets", default_branch: "main") }
  let(:client) { instance_double(GithubClient) }

  def skill_md(name:, description: "Does a thing.")
    <<~MARKDOWN
      ---
      name: #{name}
      description: #{description}
      ---
      Repo-local instructions for #{name}.
    MARKDOWN
  end

  describe ".for" do
    it "raises ArgumentError without a repository" do
      expect {
        described_class.for(repository: nil, name: "investigate")
      }.to raise_error(ArgumentError, /repository/)
    end

    it "raises ArgumentError for a blank name" do
      expect {
        described_class.for(repository: repository, name: "  ")
      }.to raise_error(ArgumentError, /name/)
    end

    it "raises ArgumentError for a name with unsafe characters" do
      expect {
        described_class.for(repository: repository, name: "../etc/passwd")
      }.to raise_error(ArgumentError, /invalid skill name/)
    end

    context "when a repo-local skill exists" do
      it "resolves to :repo_override with the resolved path and parsed definition" do
        allow(client).to receive(:file_content_at)
          .with("acme/widgets", ".syrus/skills/audit/SKILL.md", "main")
          .and_return(content: skill_md(name: "audit"), size: 50)

        resolution = described_class.for(repository: repository, name: "audit", client: client)

        expect(resolution.source).to eq(:repo_override)
        expect(resolution.path).to eq(".syrus/skills/audit/SKILL.md")
        expect(resolution.klass).to be_nil
        expect(resolution.definition.name).to eq("audit")
        expect(resolution.definition.instructions).to include("Repo-local instructions for audit")
      end

      it "shadows a built-in skill of the same name" do
        allow(client).to receive(:file_content_at)
          .with("acme/widgets", ".syrus/skills/investigate/SKILL.md", "main")
          .and_return(content: skill_md(name: "investigate", description: "Repo override of investigate."), size: 60)

        resolution = described_class.for(repository: repository, name: "investigate", client: client)

        expect(resolution.source).to eq(:repo_override)
        expect(resolution.definition.description).to eq("Repo override of investigate.")
      end

      it "propagates a parse error instead of silently falling back to a built-in" do
        allow(client).to receive(:file_content_at)
          .with("acme/widgets", ".syrus/skills/investigate/SKILL.md", "main")
          .and_return(content: "not a valid skill file", size: 20)

        expect {
          described_class.for(repository: repository, name: "investigate", client: client)
        }.to raise_error(Skills::SkillMarkdown::ParseError)
      end
    end

    context "when no repo-local skill exists" do
      it "falls back to the built-in registry" do
        allow(client).to receive(:file_content_at).and_return(nil)

        resolution = described_class.for(repository: repository, name: "investigate", client: client)

        expect(resolution.source).to eq(:built_in)
        expect(resolution.path).to be_nil
        expect(resolution.klass).to eq(Skills::Investigate)
        expect(resolution.definition).to eq(Skills::Investigate.definition)
      end

      it "raises Skills::NotFoundError when the name is unknown to both tiers" do
        allow(client).to receive(:file_content_at).and_return(nil)

        expect {
          described_class.for(repository: repository, name: "does-not-exist", client: client)
        }.to raise_error(Skills::NotFoundError, /does-not-exist/)
      end
    end

    context "when GitHub credentials are unavailable" do
      it "skips the repo-local lookup entirely and resolves the built-in" do
        user.update!(github_token: nil)
        expect(GithubClient).not_to receive(:for)

        resolution = described_class.for(repository: repository, name: "investigate", user: user)

        expect(resolution.source).to eq(:built_in)
      end
    end
  end

  describe ".all_for" do
    def tree(*paths)
      { items: paths.map { |path| { path: path, size: 10 } }, truncated: false }
    end

    it "raises ArgumentError without a repository" do
      expect {
        described_class.all_for(repository: nil)
      }.to raise_error(ArgumentError, /repository/)
    end

    it "lists only built-in skills when the repo has no .syrus/skills directory" do
      allow(client).to receive(:file_content_at).and_return(nil)
      allow(client).to receive(:file_tree_at)
        .with("acme/widgets", "main")
        .and_return(tree("README.md", ".syrus.yml"))

      resolutions = described_class.all_for(repository: repository, client: client)

      expect(resolutions.map { |r| r.definition.name }).to eq([ "add-ci-workflow", "coverage-gap-report", "dead-code-sweep", "debug", "dependency-audit", "explain-failing-ci", "init-docs", "investigate", "license-audit", "onboard-to-syrus", "security-review" ])
      expect(resolutions.first.source).to eq(:built_in)
    end

    it "includes a repo-local skill alongside built-ins, unshadowed" do
      allow(client).to receive(:file_content_at).and_return(nil)
      allow(client).to receive(:file_tree_at)
        .with("acme/widgets", "main")
        .and_return(tree(".syrus/skills/audit/SKILL.md"))
      allow(client).to receive(:file_content_at)
        .with("acme/widgets", ".syrus/skills/audit/SKILL.md", "main")
        .and_return(content: skill_md(name: "audit"), size: 50)

      resolutions = described_class.all_for(repository: repository, client: client)

      by_name = resolutions.index_by { |r| r.definition.name }
      expect(by_name.keys.sort).to eq([ "add-ci-workflow", "audit", "coverage-gap-report", "dead-code-sweep", "debug", "dependency-audit", "explain-failing-ci", "init-docs", "investigate", "license-audit", "onboard-to-syrus", "security-review" ])
      expect(by_name["audit"].source).to eq(:repo_override)
      expect(by_name["audit"].path).to eq(".syrus/skills/audit/SKILL.md")
      expect(by_name["investigate"].source).to eq(:built_in)
    end

    it "reports a repo-local skill that shadows a built-in as :repo_override" do
      allow(client).to receive(:file_tree_at)
        .with("acme/widgets", "main")
        .and_return(tree(".syrus/skills/investigate/SKILL.md"))
      allow(client).to receive(:file_content_at)
        .with("acme/widgets", ".syrus/skills/investigate/SKILL.md", "main")
        .and_return(content: skill_md(name: "investigate", description: "Repo override of investigate."), size: 60)

      resolutions = described_class.all_for(repository: repository, client: client)

      expect(resolutions.map { |r| r.definition.name }).to eq([ "add-ci-workflow", "coverage-gap-report", "dead-code-sweep", "debug", "dependency-audit", "explain-failing-ci", "init-docs", "investigate", "license-audit", "onboard-to-syrus", "security-review" ])
      investigate = resolutions.find { |r| r.definition.name == "investigate" }
      expect(investigate.source).to eq(:repo_override)
      expect(investigate.definition.description).to eq("Repo override of investigate.")
    end

    it "omits a repo-local skill whose SKILL.md fails to parse instead of raising" do
      allow(client).to receive(:file_content_at).and_return(nil)
      allow(client).to receive(:file_tree_at)
        .with("acme/widgets", "main")
        .and_return(tree(".syrus/skills/broken/SKILL.md"))
      allow(client).to receive(:file_content_at)
        .with("acme/widgets", ".syrus/skills/broken/SKILL.md", "main")
        .and_return(content: "not a valid skill file", size: 20)

      resolutions = described_class.all_for(repository: repository, client: client)

      expect(resolutions.map { |r| r.definition.name }).to eq([ "add-ci-workflow", "coverage-gap-report", "dead-code-sweep", "debug", "dependency-audit", "explain-failing-ci", "init-docs", "investigate", "license-audit", "onboard-to-syrus", "security-review" ])
    end

    it "skips the repo-local tree lookup entirely when credentials are unavailable" do
      user.update!(github_token: nil)
      expect(GithubClient).not_to receive(:for)

      resolutions = described_class.all_for(repository: repository, user: user)

      expect(resolutions.map { |r| r.definition.name }).to eq([ "add-ci-workflow", "coverage-gap-report", "dead-code-sweep", "debug", "dependency-audit", "explain-failing-ci", "init-docs", "investigate", "license-audit", "onboard-to-syrus", "security-review" ])
    end
  end
end
