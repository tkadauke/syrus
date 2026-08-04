require "rails_helper"

RSpec.describe RepoAgentInsightPlan do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets", default_branch: "main") }
  let(:client) { instance_double(GithubClient) }

  it "defaults to no prepare without credentials" do
    user.update!(github_token: nil)
    job = Struct.new(:user, :repository).new(user, repository)

    result = described_class.for_job(job)

    expect(result).not_to be_prepare
    expect(result.note).to eq("no GitHub credentials")
  end

  it "returns no prepare when .syrus.yml is absent" do
    allow(client).to receive(:file_content_at).and_return(nil)

    result = described_class.new(repository: repository, user: user, client: client).resolve

    expect(result).not_to be_prepare
    expect(result.note).to eq("no .syrus.yml")
  end

  it "honors agent_insight.prepare opt-in" do
    allow(client).to receive(:file_content_at).and_return(
      content: <<~YAML,
        prepare:
          - bundle install
        agent_insight:
          prepare: true
      YAML
      size: 67
    )

    result = described_class.new(repository: repository, user: user, client: client).resolve

    expect(result).to be_prepare
    expect(result.source).to eq(".syrus.yml")
  end

  it "does not infer prepare from the normal prepare list" do
    allow(client).to receive(:file_content_at).and_return(
      content: <<~YAML,
        prepare:
          - bundle install
      YAML
      size: 31
    )

    result = described_class.new(repository: repository, user: user, client: client).resolve

    expect(result).not_to be_prepare
    expect(result.note).to eq("no agent_insight configured")
  end
end
