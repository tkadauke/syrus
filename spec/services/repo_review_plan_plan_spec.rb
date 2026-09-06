require "rails_helper"

RSpec.describe RepoReviewPlanPlan do
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

  it "enables from the repository .syrus.yml" do
    allow(client).to receive(:file_content_at)
      .with("acme/widgets", ".syrus.yml", "main")
      .and_return(content: "review_plan: true\n", size: 20)

    result = described_class.new(repository: repository, user: user, client: client).resolve

    expect(result).to be_enabled
    expect(result.source).to eq(".syrus.yml")
    expect(result.note).to be_nil
  end

  it "is disabled when .syrus.yml is absent" do
    allow(client).to receive(:file_content_at).and_return(nil)

    result = described_class.new(repository: repository, user: user, client: client).resolve

    expect(result).not_to be_enabled
    expect(result.note).to eq("no .syrus.yml")
  end

  it "is disabled when review_plan is not configured" do
    allow(client).to receive(:file_content_at).and_return(content: "prepare: []\n", size: 12)

    result = described_class.new(repository: repository, user: user, client: client).resolve

    expect(result).not_to be_enabled
    expect(result.source).to eq(".syrus.yml")
  end

  it "is disabled when review_plan is explicitly false" do
    allow(client).to receive(:file_content_at).and_return(content: "review_plan: false\n", size: 20)

    result = described_class.new(repository: repository, user: user, client: client).resolve

    expect(result).not_to be_enabled
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
