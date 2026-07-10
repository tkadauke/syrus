require "rails_helper"

RSpec.describe RepoCoveragePlanReader do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets", default_branch: "main") }
  let(:client) { instance_double(GithubClient) }

  it "returns nil without touching GitHub when credentials are unavailable" do
    user.update!(github_token: nil)
    expect(GithubClient).not_to receive(:for)

    result = described_class.new(repository: repository, user: user).resolve

    expect(result).to be_nil
  end

  it "returns the coverage plan from .syrus.yml" do
    allow(client).to receive(:file_content_at)
      .with("acme/widgets", ".syrus.yml", "main")
      .and_return(content: <<~YAML, size: 50)
        coverage:
          artifact: coverage/lcov.info
      YAML

    result = described_class.new(repository: repository, user: user, client: client).resolve

    expect(result).to be_a(RepoCoveragePlan)
    expect(result.sources.first.artifact).to eq("coverage/lcov.info")
  end

  it "returns nil when .syrus.yml is absent" do
    allow(client).to receive(:file_content_at).and_return(nil)

    result = described_class.new(repository: repository, user: user, client: client).resolve

    expect(result).to be_nil
  end

  it "returns nil when coverage is not configured" do
    allow(client).to receive(:file_content_at).and_return(content: "prepare: []\n", size: 12)

    result = described_class.new(repository: repository, user: user, client: client).resolve

    expect(result).to be_nil
  end

  it "returns nil when the config is invalid" do
    allow(client).to receive(:file_content_at)
      .and_return(content: "coverage:\n  on_miss: invalid\n", size: 35)

    result = described_class.new(repository: repository, user: user, client: client).resolve

    expect(result).to be_nil
  end

  it "returns nil when the config cannot be fetched" do
    allow(client).to receive(:file_content_at).and_raise(StandardError, "network unavailable")

    result = described_class.new(repository: repository, user: user, client: client).resolve

    expect(result).to be_nil
  end

  it "returns nil when the GitHub client is not a GithubClient instance" do
    allow(GithubClient).to receive(:for).with(repository: repository, user: user).and_return(client)
    expect(client).not_to receive(:file_content_at)

    result = described_class.new(repository: repository, user: user).resolve

    expect(result).to be_nil
  end
end
