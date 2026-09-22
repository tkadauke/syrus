require "rails_helper"

RSpec.describe Skills do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets", default_branch: "main") }

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
        stub_repository_content(repository, files: { ".syrus/skills/audit/SKILL.md" => skill_md(name: "audit") })

        resolution = described_class.for(repository: repository, name: "audit")

        expect(resolution.source).to eq(:repo_override)
        expect(resolution.path).to eq(".syrus/skills/audit/SKILL.md")
        expect(resolution.klass).to be_nil
        expect(resolution.definition.name).to eq("audit")
        expect(resolution.definition.instructions).to include("Repo-local instructions for audit")
      end

      it "shadows a built-in skill of the same name" do
        stub_repository_content(repository, files: { ".syrus/skills/investigate/SKILL.md" => skill_md(name: "investigate", description: "Repo override of investigate.") })

        resolution = described_class.for(repository: repository, name: "investigate")

        expect(resolution.source).to eq(:repo_override)
        expect(resolution.definition.description).to eq("Repo override of investigate.")
      end

      it "propagates a parse error instead of silently falling back to a built-in" do
        stub_repository_content(repository, files: { ".syrus/skills/investigate/SKILL.md" => "not a valid skill file" })

        expect {
          described_class.for(repository: repository, name: "investigate")
        }.to raise_error(Skills::SkillMarkdown::ParseError)
      end
    end

    context "when no repo-local skill exists" do
      it "falls back to the built-in registry" do
        stub_repository_content(repository, files: {})

        resolution = described_class.for(repository: repository, name: "investigate")

        expect(resolution.source).to eq(:built_in)
        expect(resolution.path).to be_nil
        expect(resolution.klass).to eq(Skills::Investigate)
        expect(resolution.definition).to eq(Skills::Investigate.definition)
      end

      it "raises Skills::NotFoundError when the name is unknown to both tiers" do
        stub_repository_content(repository, files: {})

        expect {
          described_class.for(repository: repository, name: "does-not-exist")
        }.to raise_error(Skills::NotFoundError, /does-not-exist/)
      end
    end

    context "when no content provider serves the repository (no credentials)" do
      it "resolves the built-in" do
        RepositoryContent.provider_classes_override = []

        resolution = described_class.for(repository: repository, name: "investigate", user: user)

        expect(resolution.source).to eq(:built_in)
      end
    end

    # A repo-local skill may shadow the built-in; running the built-in
    # because GitHub was briefly unreachable would silently run the wrong
    # instructions.
    it "raises instead of falling back to a built-in when the repository cannot be read" do
      stub_repository_content_failure(repository, RepositoryContent::Unavailable.new("rate limited"))

      expect { described_class.for(repository: repository, name: "investigate") }
        .to raise_error(RepositoryContent::Unavailable)
    end
  end

  describe ".all_for" do
    before do
      described_class.remove_instance_variable(:@all_for_cache) if described_class.instance_variable_defined?(:@all_for_cache)
    end

    def stub_skills(files)
      stub_repository_content(repository, files: files)
    end

    it "raises ArgumentError without a repository" do
      expect {
        described_class.all_for(repository: nil)
      }.to raise_error(ArgumentError, /repository/)
    end

    it "lists only built-in skills when the repo has no .syrus/skills directory" do
      stub_skills("README.md" => "hi", ".syrus.yml" => "")

      resolutions = described_class.all_for(repository: repository)

      expect(resolutions.map { |r| r.definition.name }).to eq([ "add-ci-workflow", "changelog-generate", "coverage-gap-report", "dead-code-sweep", "debug", "dependency-audit", "explain-failing-ci", "init-docs", "investigate", "investigate-and-report", "license-audit", "onboard-to-syrus", "rebase-conflict-resolver", "security-review" ])
      expect(resolutions.first.source).to eq(:built_in)
    end

    it "includes a repo-local skill alongside built-ins, unshadowed" do
      stub_skills(".syrus/skills/audit/SKILL.md" => skill_md(name: "audit"))

      resolutions = described_class.all_for(repository: repository)

      by_name = resolutions.index_by { |r| r.definition.name }
      expect(by_name.keys.sort).to eq([ "add-ci-workflow", "audit", "changelog-generate", "coverage-gap-report", "dead-code-sweep", "debug", "dependency-audit", "explain-failing-ci", "init-docs", "investigate", "investigate-and-report", "license-audit", "onboard-to-syrus", "rebase-conflict-resolver", "security-review" ])
      expect(by_name["audit"].source).to eq(:repo_override)
      expect(by_name["audit"].path).to eq(".syrus/skills/audit/SKILL.md")
      expect(by_name["investigate"].source).to eq(:built_in)
    end

    it "reports a repo-local skill that shadows a built-in as :repo_override" do
      stub_skills(".syrus/skills/investigate/SKILL.md" => skill_md(name: "investigate", description: "Repo override of investigate."))

      resolutions = described_class.all_for(repository: repository)

      expect(resolutions.map { |r| r.definition.name }).to eq([ "add-ci-workflow", "changelog-generate", "coverage-gap-report", "dead-code-sweep", "debug", "dependency-audit", "explain-failing-ci", "init-docs", "investigate", "investigate-and-report", "license-audit", "onboard-to-syrus", "rebase-conflict-resolver", "security-review" ])
      investigate = resolutions.find { |r| r.definition.name == "investigate" }
      expect(investigate.source).to eq(:repo_override)
      expect(investigate.definition.description).to eq("Repo override of investigate.")
    end

    it "omits a repo-local skill whose SKILL.md fails to parse instead of raising" do
      stub_skills(".syrus/skills/broken/SKILL.md" => "not a valid skill file")

      resolutions = described_class.all_for(repository: repository)

      expect(resolutions.map { |r| r.definition.name }).to eq([ "add-ci-workflow", "changelog-generate", "coverage-gap-report", "dead-code-sweep", "debug", "dependency-audit", "explain-failing-ci", "init-docs", "investigate", "investigate-and-report", "license-audit", "onboard-to-syrus", "rebase-conflict-resolver", "security-review" ])
    end

    it "lists only built-ins when no content provider serves the repository" do
      RepositoryContent.provider_classes_override = []

      resolutions = described_class.all_for(repository: repository, user: user)

      expect(resolutions.map { |r| r.definition.name }).to eq([ "add-ci-workflow", "changelog-generate", "coverage-gap-report", "dead-code-sweep", "debug", "dependency-audit", "explain-failing-ci", "init-docs", "investigate", "investigate-and-report", "license-audit", "onboard-to-syrus", "rebase-conflict-resolver", "security-review" ])
    end

    it "caches repository skill listings briefly" do
      first = [ Skills::Resolution.new(source: :built_in, path: nil, klass: Skills::Investigate, definition: Skills::Investigate.definition) ]
      second = [ Skills::Resolution.new(source: :built_in, path: nil, klass: Skills::Debug, definition: Skills::Debug.definition) ]
      now = 1_000.0

      allow(described_class).to receive(:uncached_all_for).and_return(first, second)
      allow(described_class).to receive(:all_for_cache_now).and_return(now, now + 1, now + Skills::ALL_FOR_CACHE_TTL.to_f + 1)

      expect(described_class.all_for(repository: repository, user: user)).to eq(first)
      expect(described_class.all_for(repository: repository, user: user)).to eq(first)
      expect(described_class.all_for(repository: repository, user: user)).to eq(second)

      expect(described_class).to have_received(:uncached_all_for).twice
    end
  end
end
