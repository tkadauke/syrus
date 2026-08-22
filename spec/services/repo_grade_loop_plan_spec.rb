require "rails_helper"

RSpec.describe RepoGradeLoopPlan do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets", default_branch: "main") }
  let(:client) { instance_double(GithubClient) }

  it "is unconfigured without touching GitHub when credentials are unavailable" do
    user.update!(github_token: nil)
    expect(GithubClient).not_to receive(:for)

    result = described_class.new(repository: repository, user: user).resolve

    expect(result).not_to be_any_configured
    expect(result.note).to eq("no GitHub credentials")
  end

  it "is unconfigured when .syrus.yml is absent" do
    allow(client).to receive(:file_content_at).and_return(nil)

    result = described_class.new(repository: repository, user: user, client: client).resolve

    expect(result).not_to be_any_configured
    expect(result.note).to eq("no .syrus.yml")
  end

  it "is unconfigured when none of formatters/generated/grade are declared" do
    allow(client).to receive(:file_content_at)
      .with("acme/widgets", ".syrus.yml", "main")
      .and_return(content: "prepare: []\n", size: 12)

    result = described_class.new(repository: repository, user: user, client: client).resolve

    expect(result.format_configured).to eq(false)
    expect(result.generate_configured).to eq(false)
    expect(result.graders_configured).to eq(false)
    expect(result).not_to be_any_configured
  end

  it "reports format_configured when formatters is a non-empty array" do
    allow(client).to receive(:file_content_at)
      .with("acme/widgets", ".syrus.yml", "main")
      .and_return(content: <<~YAML, size: 60)
        formatters:
          - command: rubocop -a
            files: "**/*.rb"
      YAML

    result = described_class.new(repository: repository, user: user, client: client).resolve

    expect(result.format_configured).to eq(true)
    expect(result.generate_configured).to eq(false)
    expect(result.graders_configured).to eq(false)
    expect(result).to be_any_configured
  end

  it "reports generate_configured when generated is a non-empty array" do
    allow(client).to receive(:file_content_at)
      .with("acme/widgets", ".syrus.yml", "main")
      .and_return(content: <<~YAML, size: 80)
        generated:
          - command: bin/rails db:schema:dump
            generates: "db/schema.rb"
      YAML

    result = described_class.new(repository: repository, user: user, client: client).resolve

    expect(result.generate_configured).to eq(true)
    expect(result.format_configured).to eq(false)
    expect(result.graders_configured).to eq(false)
    expect(result).to be_any_configured
  end

  it "reports graders_configured when grade steps are declared" do
    allow(client).to receive(:file_content_at)
      .with("acme/widgets", ".syrus.yml", "main")
      .and_return(content: <<~YAML, size: 40)
        grade:
          - name: tests
            run: bin/rspec
      YAML

    result = described_class.new(repository: repository, user: user, client: client).resolve

    expect(result.graders_configured).to eq(true)
    expect(result.format_configured).to eq(false)
    expect(result.generate_configured).to eq(false)
    expect(result).to be_any_configured
  end

  it "is unconfigured when formatters/generated are explicitly disabled and grade has no steps" do
    allow(client).to receive(:file_content_at)
      .with("acme/widgets", ".syrus.yml", "main")
      .and_return(content: <<~YAML, size: 60)
        formatters: false
        generated: false
        grade: []
      YAML

    result = described_class.new(repository: repository, user: user, client: client).resolve

    expect(result).not_to be_any_configured
  end

  it "is unconfigured when the config is invalid" do
    allow(client).to receive(:file_content_at).and_return(content: "grade:\n  max_iterations: many\n", size: 35)

    result = described_class.new(repository: repository, user: user, client: client).resolve

    expect(result).not_to be_any_configured
    expect(result.note).to match(/grade\.max_iterations: must be an integer/)
  end

  it "is unconfigured when the config cannot be fetched" do
    allow(client).to receive(:file_content_at).and_raise(StandardError, "network unavailable")

    result = described_class.new(repository: repository, user: user, client: client).resolve

    expect(result).not_to be_any_configured
    expect(result.note).to eq("network unavailable")
  end

  it "is unconfigured when workflow setup has an unrelated GithubClient test double" do
    allow(GithubClient).to receive(:for).with(repository: repository, user: user).and_return(client)
    expect(client).not_to receive(:file_content_at)

    result = described_class.new(repository: repository, user: user).resolve

    expect(result).not_to be_any_configured
    expect(result.note).to eq("GitHub client unavailable")
  end
end
