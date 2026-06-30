require "rails_helper"

RSpec.describe RepoAdversarialReviewPlan do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets", default_branch: "main") }
  let(:client) { instance_double(GithubClient) }

  before do
    allow(GithubClient).to receive(:for).with(repository: repository, user: user).and_return(client)
  end

  it "enables rounds from the repository .syrus.yml" do
    allow(client).to receive(:file_content_at)
      .with("acme/widgets", ".syrus.yml", "main")
      .and_return(content: <<~YAML, size: 40)
        adversarial_review:
          rounds: 2
      YAML

    result = described_class.new(repository: repository, user: user).resolve

    expect(result).to be_enabled
    expect(result.rounds).to eq(2)
    expect(result.source).to eq(".syrus.yml")
  end

  it "is disabled when .syrus.yml is absent" do
    allow(client).to receive(:file_content_at).and_return(nil)

    result = described_class.new(repository: repository, user: user).resolve

    expect(result).not_to be_enabled
    expect(result.rounds).to eq(0)
    expect(result.note).to eq("no .syrus.yml")
  end

  it "is disabled when adversarial review is not configured" do
    allow(client).to receive(:file_content_at).and_return(content: "prepare: []\n", size: 12)

    result = described_class.new(repository: repository, user: user).resolve

    expect(result).not_to be_enabled
    expect(result.note).to eq("no adversarial_review configured")
  end

  it "is disabled when the config is invalid" do
    allow(client).to receive(:file_content_at).and_return(content: "adversarial_review:\n  rounds: many\n", size: 35)

    result = described_class.new(repository: repository, user: user).resolve

    expect(result).not_to be_enabled
    expect(result.note).to match(/adversarial_review\.rounds: must be an integer/)
  end
end
