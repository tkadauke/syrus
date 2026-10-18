require "rails_helper"

RSpec.describe RepositoryReadiness do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user:) }
  let(:worker_decision) do
    RunQueueResolver::Decision.new(queue_name: "runs", requirements: { "os" => [ "linux" ] }, sticky_resume: false, blocked_reason: nil, details: {})
  end

  before do
    user.update!(github_token: "github-token")
    allow(RunQueueResolver).to receive(:resolve_candidate).and_return(worker_decision)
  end

  it "reports exact configured commands and advisory static hints without executing repository code" do
    stub_repository_content(repository, files: {
      ".syrus.yml" => <<~YAML,
        prepare:
          - bundle install
        grade:
          - name: specs
            run: bin/rspec
        project:
          capabilities:
            os: [linux]
            runtime: [docker]
      YAML
      "Gemfile" => "source 'https://rubygems.org'\n",
      "docker-compose.yml" => "services: {}\n",
      ".ruby-version" => "3.4.10\n"
    })

    result = described_class.call(repository:, user:)

    expect(result.status).to eq("ready_with_warnings")
    expect(result.prepare_commands).to eq([ "bundle install" ])
    expect(result.grader_commands).to eq([ "bin/rspec" ])
    expect(result.required_capabilities).to include("runtime" => [ "docker" ])
    expect(result.checks).to include(include(key: "access", level: "pass"))
    expect(result.checks).to include(include(key: "environment", level: "warning", message: /Docker/))
  end

  it "hard-blocks invalid configuration as needs configuration" do
    stub_repository_content(repository, files: { ".syrus.yml" => "prepare: [\n" })

    result = described_class.call(repository:, user:)

    expect(result.status).to eq("needs_configuration")
    expect(result.checks).to include(include(key: "configuration", level: "block"))
  end

  it "classifies the absence of a capable worker as incompatible" do
    stub_repository_content(repository, files: { ".syrus.yml" => "prepare: []\n" })
    allow(RunQueueResolver).to receive(:resolve_candidate).and_return(worker_decision.with(blocked_reason: "no_live_worker_for_capabilities"))

    result = described_class.call(repository:, user:)

    expect(result.status).to eq("incompatible")
    expect(result.checks).to include(include(key: "worker", level: "block"))
  end

  it "hard-blocks missing clone credentials" do
    user.update!(github_token: nil)
    stub_repository_content(repository, files: { ".syrus.yml" => "prepare: []\n" })

    result = described_class.call(repository:, user:)

    expect(result.status).to eq("needs_configuration")
    expect(result.checks).to include(include(key: "credentials", level: "block"))
  end

  it "treats missing configuration and inferred commands as warnings" do
    stub_repository_content(repository, files: { "Gemfile" => "source 'https://rubygems.org'\n" })

    result = described_class.call(repository:, user:)

    expect(result.status).to eq("ready_with_warnings")
    expect(result.checks).to include(include(key: "configuration", level: "warning"))
  end
end
