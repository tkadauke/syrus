require "rails_helper"

RSpec.describe RepoDeploymentStagesReader do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets", default_branch: "main") }
  let(:stages_yml) do
    <<~YAML
      deployment_stages:
        - name: staging
          label: Staging
          tag: staging
    YAML
  end

  before do
    described_class.clear_cache!
  end

  after do
    described_class.clear_cache!
  end

  def reads
    FakeRepositoryContentProvider.calls.count { |call| call.first == :read }
  end

  it "returns a disabled plan when .syrus.yml cannot be read" do
    stub_repository_content_failure(repository, RepositoryContent::Unavailable.new("rate limited"))

    result = described_class.new(repository: repository, user: user).resolve

    expect(result).not_to be_enabled
    expect(result.note).to eq("rate limited")
  end

  it "returns a disabled plan when the repository has no .syrus.yml" do
    stub_repository_content(repository, files: {})

    expect(described_class.new(repository: repository, user: user).resolve.note).to eq("no .syrus.yml")
  end

  it "returns deployment stages from .syrus.yml" do
    stub_repository_content(repository, files: { ".syrus.yml" => stages_yml })

    result = described_class.new(repository: repository, user: user).resolve

    expect(result).to be_enabled
    expect(result.stages.first.name).to eq("staging")
  end

  it "caches repository lookups within the process TTL" do
    stub_repository_content(repository, files: { ".syrus.yml" => stages_yml })

    first = described_class.for_repository(repository)
    second = described_class.for_repository(repository)

    expect(first).to be_enabled
    expect(second.stages.first.name).to eq("staging")
    expect(reads).to eq(1)
  end

  it "can bypass the process cache" do
    stub_repository_content(repository, files: { ".syrus.yml" => stages_yml })

    described_class.for_repository(repository, cached: false)
    described_class.for_repository(repository, cached: false)

    expect(reads).to eq(2)
  end
end
