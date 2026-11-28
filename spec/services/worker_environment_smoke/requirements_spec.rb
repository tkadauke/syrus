require "rails_helper"

RSpec.describe WorkerEnvironmentSmoke::Requirements do
  let(:job) { Factories.job }
  let(:workflow) { Workflow.create!(job: job, trigger_kind: "initial", agent_provider: "codex") }

  def step(kind)
    Step.create!(workflow: workflow, kind: kind, position: workflow.steps.count)
  end

  it "asks every step for the data root, temp space and git" do
    expect(described_class.for(workflow: workflow, step: step("prepare"))).to contain_exactly("workflow_data_root", "tmp", "git")
  end

  it "asks an agentic step for its agent provider's CLI" do
    expect(described_class.for(workflow: workflow, step: step("implement"))).to include("agent_cli_codex")
    expect(described_class.for(workflow: workflow, step: step("prepare"))).not_to include("agent_cli_codex")
  end

  it "prefers the Run's own agent provider over the workflow's" do
    implement = step("implement")
    run = implement.runs.create!(job: job, trigger_kind: "initial", agent_provider: "claude")

    expect(described_class.for(workflow: workflow, step: implement, run: run)).to include("agent_cli_claude")
  end

  it "asks for gh only when the workflow was granted break-glass GitHub access" do
    implement = step("implement")
    expect(described_class.for(workflow: workflow, step: implement)).not_to include("gh")

    workflow.set_artifact!("manual_agentic_run_github_access", true)

    expect(described_class.for(workflow: workflow, step: implement)).to include("gh")
  end

  it "adds the checks a step kind declares" do
    entry = Step::Kind::Entry.new(kind: "prepare", handler: "Prepare", label: "Prepare", style: "", agentic: false,
      worker_checks: [ { "name" => "browser", "command" => %w[playwright-mcp --version] } ])
    allow(Step::Kind).to receive(:fetch).and_call_original
    allow(Step::Kind).to receive(:fetch).with("prepare").and_return(entry)

    expect(described_class.for(workflow: workflow, step: step("prepare"))).to include("browser")
  end

  it "adds what the repository's prepare plan was recorded to need" do
    job.repository.update!(worker_environment_requirements: %w[bundler c_compiler mysql_client ruby])

    expect(described_class.for(workflow: workflow, step: step("prepare")))
      .to include("bundler", "c_compiler", "mysql_client", "ruby")
  end

  it "declares the browser check on the browser plugin's visual review step kinds" do
    %w[visual_review visual_diff].each do |kind|
      expect(Step::Kind.fetch(kind).worker_checks).to include(hash_including("name" => "browser", "command" => %w[playwright-mcp --version]))
    end
  end
end

RSpec.describe WorkerEnvironmentSmoke::RepositoryNeeds do
  around do |example|
    Dir.mktmpdir("repository-needs-spec-") do |dir|
      @workspace = dir
      example.run
    end
  end

  it "maps prepare commands, through wrappers and env assignments, to the checks they need" do
    needs = described_class.detect(@workspace, commands: [
      "BUNDLE_JOBS=4 bundle install", "mise exec -- npm ci && yarn build", "make setup"
    ])

    expect(needs).to eq(%w[bundler c_compiler node npm ruby])
  end

  it "asks for a MySQL client when the lockfile builds mysql2" do
    File.write(File.join(@workspace, "Gemfile.lock"), "GEM\n  specs:\n    mysql2 (0.5.7)\n    rails (8.1.4)\n")

    expect(described_class.detect(@workspace, commands: [ "bundle install" ])).to include("mysql_client", "c_compiler")
  end

  it "does not ask for a MySQL client for a lockfile without mysql2" do
    File.write(File.join(@workspace, "Gemfile.lock"), "GEM\n  specs:\n    sqlite3 (2.10.2)\n    activerecord-mysql2-adapter-compat (1.0)\n")

    expect(described_class.detect(@workspace, commands: [ "bundle install" ])).not_to include("mysql_client")
  end

  it "records the needs on the repository only when they changed" do
    repository = Factories.job.repository

    described_class.record!(repository, %w[ruby bundler])
    expect(repository.reload.worker_environment_requirements).to eq(%w[bundler ruby])

    expect(repository).not_to receive(:update_columns)
    described_class.record!(repository, %w[bundler ruby])
  end
end
