require "rails_helper"

RSpec.describe RepoDefaultBranchSyrusYml do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets", default_branch: "main") }
  def resolve = described_class.new(repository: repository, user: user).resolve

  it "is unavailable when no content provider serves the repository" do
    RepositoryContent.provider_classes_override = []

    result = resolve

    expect(result.config).to be_nil
    expect(result.source).to eq("none")
    expect(result.note).to match(/no repository content provider/)
    expect(result.outcome).to eq(:unavailable)
    expect(result).not_to be_determined
  end

  # The one real absence: a provider answered, and there is no such file.
  it "is absent, and determined, when .syrus.yml does not exist" do
    stub_repository_content(repository, files: { "README.md" => "hi" })

    result = resolve

    expect(result.config).to be_nil
    expect(result.source).to eq("none")
    expect(result.note).to eq("no .syrus.yml")
    expect(result.outcome).to eq(:absent)
    expect(result).to be_determined
  end

  it "exposes the parsed SyrusYml::Config from the default branch on success" do
    stub_repository_content(repository, ref: "release", files: { ".syrus.yml" => "adversarial_review:\n  rounds: 5\n" })
    stub_repository_content(repository, ref: "main", files: { ".syrus.yml" => <<~YAML })
      adversarial_review:
        rounds: 2
    YAML

    result = resolve

    expect(result.config).to be_a(SyrusYml::Config)
    expect(result.config.adversarial_review.rounds).to eq(2)
    expect(result.source).to eq(".syrus.yml")
    expect(result.note).to be_nil
    expect(result.outcome).to eq(:loaded)
    expect(result).to be_determined
  end

  it "is invalid, and undetermined, when the config does not parse" do
    stub_repository_content(repository, files: { ".syrus.yml" => "adversarial_review:\n  rounds: many\n" })

    result = resolve

    expect(result.config).to be_nil
    expect(result.source).to eq(".syrus.yml")
    expect(result.note).to match(/adversarial_review\.rounds: must be an integer/)
    expect(result.outcome).to eq(:invalid)
    expect(result).not_to be_determined
  end

  # The bug this distinction exists for: a failed read used to look exactly
  # like the absent case above, so a rate limit at workflow creation built a
  # workflow with no grade loop.
  it "is unavailable, not absent, when the config cannot be fetched" do
    stub_repository_content_failure(repository, RepositoryContent::Unavailable.new("rate limited"))

    result = resolve

    expect(result.config).to be_nil
    expect(result.source).to eq("none")
    expect(result.note).to eq("rate limited")
    expect(result.outcome).to eq(:unavailable)
    expect(result).not_to be_determined
  end

  it "is unavailable, not absent, when the default branch cannot be resolved" do
    stub_repository_content(repository, ref: "some-other-branch", files: {})

    expect(resolve.outcome).to eq(:unavailable)
  end

  # Existing constructions pass only config/source/note. Their meaning must
  # not change underneath them.
  it "infers the outcome from config when none is given" do
    expect(described_class::Result.new(config: nil, source: "none", note: "x").outcome).to eq(:absent)
    expect(described_class::Result.new(config: SyrusYml.new("").parse, source: ".syrus.yml", note: nil).outcome).to eq(:loaded)
  end

  describe ".for_job" do
    it "resolves from the job's repository and user" do
      stub_repository_content(repository, files: { ".syrus.yml" => "review_plan: true\n" })
      job = instance_double(Job, repository: repository, user: user)

      expect(described_class.for_job(job).outcome).to eq(:loaded)
    end
  end
end
