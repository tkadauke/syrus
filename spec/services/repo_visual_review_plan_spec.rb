require "rails_helper"

RSpec.describe RepoVisualReviewPlan do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets", default_branch: "main") }
  let(:client) { instance_double(GithubClient) }

  it "falls back to the instance default without touching GitHub when credentials are unavailable" do
    user.update!(github_token: nil)
    expect(GithubClient).not_to receive(:for)
    allow(AppSetting).to receive(:visual_review_enabled?).and_return(true)

    result = described_class.new(repository: repository, user: user).resolve

    expect(result).to be_enabled
    expect(result.note).to eq("no GitHub credentials")
  end

  it "enables from the repository .syrus.yml, overriding the instance default" do
    allow(AppSetting).to receive(:visual_review_enabled?).and_return(false)
    allow(client).to receive(:file_content_at)
      .with("acme/widgets", ".syrus.yml", "main")
      .and_return(content: <<~YAML, size: 40)
        visual_review:
          enabled: true
          rounds: 2
      YAML

    result = described_class.new(repository: repository, user: user, client: client).resolve

    expect(result).to be_enabled
    expect(result.rounds).to eq(2)
    expect(result.source).to eq(".syrus.yml")
  end

  it "disables via explicit repository opt-out, overriding an enabled instance default" do
    allow(AppSetting).to receive(:visual_review_enabled?).and_return(true)
    allow(client).to receive(:file_content_at)
      .with("acme/widgets", ".syrus.yml", "main")
      .and_return(content: <<~YAML, size: 40)
        visual_review:
          enabled: false
      YAML

    result = described_class.new(repository: repository, user: user, client: client).resolve

    expect(result).not_to be_enabled
    expect(result.source).to eq(".syrus.yml")
  end

  it "falls back to the instance-wide default when .syrus.yml is absent" do
    allow(AppSetting).to receive(:visual_review_enabled?).and_return(true)
    allow(client).to receive(:file_content_at).and_return(nil)

    result = described_class.new(repository: repository, user: user, client: client).resolve

    expect(result).to be_enabled
    expect(result.rounds).to eq(SyrusYml::DEFAULT_VISUAL_REVIEW_ROUNDS)
    expect(result.note).to eq("no .syrus.yml")
  end

  it "falls back to the instance-wide default when visual_review is not configured" do
    allow(AppSetting).to receive(:visual_review_enabled?).and_return(false)
    allow(client).to receive(:file_content_at).and_return(content: "prepare: []\n", size: 12)

    result = described_class.new(repository: repository, user: user, client: client).resolve

    expect(result).not_to be_enabled
    expect(result.note).to eq("no visual_review configured")
  end

  it "falls back to the instance-wide default when the config is invalid" do
    allow(AppSetting).to receive(:visual_review_enabled?).and_return(false)
    allow(client).to receive(:file_content_at).and_return(content: "visual_review:\n  rounds: many\n", size: 35)

    result = described_class.new(repository: repository, user: user, client: client).resolve

    expect(result).not_to be_enabled
    expect(result.note).to match(/visual_review\.rounds: must be an integer/)
  end

  it "falls back to the instance-wide default when the config cannot be fetched" do
    allow(AppSetting).to receive(:visual_review_enabled?).and_return(false)
    allow(client).to receive(:file_content_at).and_raise(StandardError, "network unavailable")

    result = described_class.new(repository: repository, user: user, client: client).resolve

    expect(result).not_to be_enabled
    expect(result.note).to eq("network unavailable")
  end

  it "falls back to the instance-wide default when workflow setup has an unrelated GitHubClient test double" do
    allow(AppSetting).to receive(:visual_review_enabled?).and_return(false)
    allow(GithubClient).to receive(:for).with(repository: repository, user: user).and_return(client)
    expect(client).not_to receive(:file_content_at)

    result = described_class.new(repository: repository, user: user).resolve

    expect(result).not_to be_enabled
    expect(result.note).to eq("GitHub client unavailable")
  end
end
