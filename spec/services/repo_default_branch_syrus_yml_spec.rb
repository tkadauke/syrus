require "rails_helper"

RSpec.describe RepoDefaultBranchSyrusYml do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets", default_branch: "main") }
  let(:client) { instance_double(GithubClient) }

  it "is unavailable without touching GitHub when credentials are unavailable" do
    user.update!(github_token: nil)
    expect(GithubClient).not_to receive(:for)

    result = described_class.new(repository: repository, user: user).resolve

    expect(result.config).to be_nil
    expect(result.source).to eq("none")
    expect(result.note).to eq("no GitHub credentials")
    expect(result.outcome).to eq(:unavailable)
    expect(result).not_to be_determined
  end

  it "is unavailable when the GitHub client is not a GithubClient instance" do
    allow(GithubClient).to receive(:for).with(repository: repository, user: user).and_return(client)
    expect(client).not_to receive(:file_content_at)

    result = described_class.new(repository: repository, user: user).resolve

    expect(result.config).to be_nil
    expect(result.source).to eq("none")
    expect(result.note).to eq("GitHub client unavailable")
    expect(result.outcome).to eq(:unavailable)
  end

  # The one real absence: GitHub answered, and there is no such file.
  it "is absent, and determined, when .syrus.yml does not exist" do
    allow(client).to receive(:file_content_at).and_return(nil)

    result = described_class.new(repository: repository, user: user, client: client).resolve

    expect(result.config).to be_nil
    expect(result.source).to eq("none")
    expect(result.note).to eq("no .syrus.yml")
    expect(result.outcome).to eq(:absent)
    expect(result).to be_determined
  end

  it "exposes the parsed SyrusYml::Config on success" do
    allow(client).to receive(:file_content_at)
      .with("acme/widgets", ".syrus.yml", "main")
      .and_return(content: <<~YAML, size: 40)
        adversarial_review:
          rounds: 2
      YAML

    result = described_class.new(repository: repository, user: user, client: client).resolve

    expect(result.config).to be_a(SyrusYml::Config)
    expect(result.config.adversarial_review.rounds).to eq(2)
    expect(result.source).to eq(".syrus.yml")
    expect(result.note).to be_nil
    expect(result.outcome).to eq(:loaded)
    expect(result).to be_determined
  end

  it "is invalid, and undetermined, when the config does not parse" do
    allow(client).to receive(:file_content_at).and_return(content: "adversarial_review:\n  rounds: many\n", size: 35)

    result = described_class.new(repository: repository, user: user, client: client).resolve

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
    allow(client).to receive(:file_content_at).and_raise(StandardError, "network unavailable")

    result = described_class.new(repository: repository, user: user, client: client).resolve

    expect(result.config).to be_nil
    expect(result.source).to eq("none")
    expect(result.note).to eq("network unavailable")
    expect(result.outcome).to eq(:unavailable)
    expect(result).not_to be_determined
  end

  it "reads a rate limit as unavailable rather than as a missing file" do
    allow(client).to receive(:file_content_at).and_raise(Octokit::TooManyRequests)

    result = described_class.new(repository: repository, user: user, client: client).resolve

    expect(result.outcome).to eq(:unavailable)
  end

  # Existing constructions pass only config/source/note. Their meaning must
  # not change underneath them.
  it "infers the outcome from config when none is given" do
    expect(described_class::Result.new(config: nil, source: "none", note: "x").outcome).to eq(:absent)
    expect(described_class::Result.new(config: SyrusYml.new("").parse, source: ".syrus.yml", note: nil).outcome).to eq(:loaded)
  end

  describe ".for_job" do
    it "resolves from the job's repository and user" do
      user.update!(github_token: nil)
      job = instance_double(Job, repository: repository, user: user)

      result = described_class.for_job(job)

      expect(result.config).to be_nil
      expect(result.note).to eq("no GitHub credentials")
    end
  end
end
