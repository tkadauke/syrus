require "rails_helper"

RSpec.describe RepoAdversarialReviewPlan do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets", default_branch: "main") }
  let(:client) { instance_double(GithubClient) }

  it "is disabled without touching GitHub when credentials are unavailable" do
    user.update!(github_token: nil)
    expect(GithubClient).not_to receive(:for)

    result = described_class.new(repository: repository, user: user).resolve

    expect(result).not_to be_enabled
    expect(result.note).to eq("no GitHub credentials")
  end

  it "enables rounds from the repository .syrus.yml" do
    allow(client).to receive(:file_content_at)
      .with("acme/widgets", ".syrus.yml", "main")
      .and_return(content: <<~YAML, size: 40)
        adversarial_review:
          rounds: 2
      YAML

    result = described_class.new(repository: repository, user: user, client: client).resolve

    expect(result).to be_enabled
    expect(result.rounds).to eq(2)
    expect(result.source).to eq(".syrus.yml")
    expect(result.criteria).to eq([])
  end

  it "carries criteria from the repository .syrus.yml" do
    allow(client).to receive(:file_content_at)
      .with("acme/widgets", ".syrus.yml", "main")
      .and_return(content: <<~YAML, size: 80)
        adversarial_review:
          rounds: 1
          criteria:
            - Verify authentication on new endpoints
            - No internal state in error messages
      YAML

    result = described_class.new(repository: repository, user: user, client: client).resolve

    expect(result.criteria).to eq([
      "Verify authentication on new endpoints",
      "No internal state in error messages"
    ])
  end

  it "is disabled when .syrus.yml is absent" do
    allow(client).to receive(:file_content_at).and_return(nil)

    result = described_class.new(repository: repository, user: user, client: client).resolve

    expect(result).not_to be_enabled
    expect(result.rounds).to eq(0)
    expect(result.note).to eq("no .syrus.yml")
    expect(result.criteria).to eq([])
  end

  it "is disabled when adversarial review is not configured" do
    allow(client).to receive(:file_content_at).and_return(content: "prepare: []\n", size: 12)

    result = described_class.new(repository: repository, user: user, client: client).resolve

    expect(result).not_to be_enabled
    expect(result.note).to eq("no adversarial_review configured")
  end

  it "is disabled when the config is invalid" do
    allow(client).to receive(:file_content_at).and_return(content: "adversarial_review:\n  rounds: many\n", size: 35)

    result = described_class.new(repository: repository, user: user, client: client).resolve

    expect(result).not_to be_enabled
    expect(result.note).to match(/adversarial_review\.rounds: must be an integer/)
  end

  it "is disabled when the config cannot be fetched" do
    allow(client).to receive(:file_content_at).and_raise(StandardError, "network unavailable")

    result = described_class.new(repository: repository, user: user, client: client).resolve

    expect(result).not_to be_enabled
    expect(result.note).to eq("network unavailable")
  end

  it "is disabled when workflow setup has an unrelated GitHubClient test double" do
    allow(GithubClient).to receive(:for).with(repository: repository, user: user).and_return(client)
    expect(client).not_to receive(:file_content_at)

    result = described_class.new(repository: repository, user: user).resolve

    expect(result).not_to be_enabled
    expect(result.note).to eq("GitHub client unavailable")
  end
end
