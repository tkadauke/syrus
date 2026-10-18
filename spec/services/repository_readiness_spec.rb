require "rails_helper"

RSpec.describe RepositoryReadiness do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user:) }
  let(:worker_decision) do
    RunQueueResolver::Decision.new(
      queue_name: "runs", requirements: { "os" => [ "linux" ] }, sticky_resume: false, blocked_reason: nil,
      details: { "live_workers" => [ { "eligible" => true } ] }
    )
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

  it "requires a live worker for the default Linux scope" do
    stub_repository_content(repository, files: { ".syrus.yml" => "prepare: []\n" })
    allow(RunQueueResolver).to receive(:resolve_candidate).and_call_original

    result = described_class.call(repository:, user:)

    expect(result.status).to eq("incompatible")
    expect(result.execution_scopes).to include(include(key: "workflow", capabilities: { "os" => [ "linux" ] }, worker_available: false))
  end

  it "evaluates independently scheduled Linux and macOS graders against separate workers" do
    ensure_solid_queue_test_tables!
    create_worker("linux-worker", "runs", "os" => [ "linux" ], "arch" => [ "amd64" ])
    create_worker("mac-worker", "runs-macos-arm64", "os" => [ "macos" ], "arch" => [ "arm64" ])
    allow(RunQueueResolver).to receive(:resolve_candidate).and_call_original
    stub_repository_content(repository, files: {
      ".syrus.yml" => <<~YAML
        prepare: []
        grade:
          - name: linux
            run: bin/linux-specs
            capabilities:
              os: [linux]
          - name: macos
            run: bin/macos-specs
            capabilities:
              os: [macos]
              arch: [arm64]
      YAML
    })

    result = described_class.call(repository:, user:)

    expect(result.status).to eq("ready")
    expect(result.execution_scopes).to include(
      include(key: "grader:linux", capabilities: { "os" => [ "linux" ] }, worker_available: true),
      include(key: "grader:macos", capabilities: { "os" => [ "macos" ], "arch" => [ "arm64" ] }, worker_available: true)
    )
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


  def create_worker(hostname, queues, capabilities)
    SolidQueue::Process.create!(
      hostname:, kind: "Worker", name: hostname, pid: 123, last_heartbeat_at: Time.current,
      metadata: { "queues" => queues, "capabilities" => capabilities, "polling_interval" => 0.1, "pool_size" => 1 }
    )
  end
end
