require "rails_helper"

RSpec.describe AgentInsights::RepoPlan do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets", default_branch: "main") }

  it "defaults to no prepare when .syrus.yml cannot be read" do
    stub_repository_content_failure(repository, RepositoryContent::Unavailable.new("rate limited"))
    job = Struct.new(:user, :repository).new(user, repository)

    result = described_class.for_job(job)

    expect(result).not_to be_prepare
    expect(result.note).to eq("rate limited")
  end

  it "returns no prepare when .syrus.yml is absent" do
    stub_repository_content(repository, files: {})

    result = described_class.new(repository: repository, user: user).resolve

    expect(result).not_to be_prepare
    expect(result.note).to eq("no .syrus.yml")
  end

  it "honors agent_insight.prepare opt-in" do
    stub_repository_content(repository, files: { ".syrus.yml" => <<~YAML })
      prepare:
        - bundle install
      agent_insight:
        prepare: true
    YAML

    result = described_class.new(repository: repository, user: user).resolve

    expect(result).to be_prepare
    expect(result.source).to eq(".syrus.yml")
  end

  it "does not infer prepare from the normal prepare list" do
    stub_repository_content(repository, files: { ".syrus.yml" => <<~YAML })
      prepare:
        - bundle install
    YAML

    result = described_class.new(repository: repository, user: user).resolve

    expect(result).not_to be_prepare
    expect(result.note).to eq("no agent_insight configured")
  end
end
