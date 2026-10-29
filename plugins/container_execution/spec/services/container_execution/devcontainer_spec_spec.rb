require "rails_helper"

RSpec.describe ContainerExecution::DevcontainerSpec do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets", default_branch: "main") }
  let(:job) { instance_double(Job, repository: repository, user: user) }

  it "reads the conventional nested spec through RepositoryContent and accepts JSON comments" do
    stub_repository_content(repository, files: {
      ".devcontainer/devcontainer.json" => <<~JSON
        {
          // Keep the development image aligned with Codespaces.
          "image": "ghcr.io/acme/widgets:dev",
        }
      JSON
    })

    result = described_class.for_job(job)

    expect(result.image).to eq("ghcr.io/acme/widgets:dev")
    expect(result.source).to eq(".devcontainer/devcontainer.json")
  end

  it "falls back to the root spec and preserves comment-shaped string content" do
    stub_repository_content(repository, files: {
      ".devcontainer.json" => '{"image":"registry.example.test/acme/widgets:dev/*stable*/"}'
    })

    expect(described_class.for_job(job).image).to eq("registry.example.test/acme/widgets:dev/*stable*/")
  end

  it "returns nil for absent, invalid, or unusable specs" do
    stub_repository_content(repository, files: { "README.md" => "hi" })
    expect(described_class.for_job(job)).to be_nil

    stub_repository_content(repository, files: { ".devcontainer.json" => "not json" })
    expect(described_class.for_job(job)).to be_nil

    stub_repository_content(repository, files: { ".devcontainer.json" => '{"features":{}}' })
    expect(described_class.for_job(job)).to be_nil
  end
end
