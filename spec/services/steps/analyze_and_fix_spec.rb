require "rails_helper"
require "tmpdir"

RSpec.describe Steps::AnalyzeAndFix do
  let(:user)       { Factories.user(github_token: "ghp_test_token") }
  let(:repository) { Factories.repository(user: user) }
  let(:job)        { Factories.job(repository: repository, pr_number: 17, branch_name: "syrus/issue-42-1") }
  let(:workflow)   { Workflows::CiFailure.instantiate(job: job, artifacts: artifacts) }
  let(:step)       { workflow.steps.find_by(kind: "analyze_and_fix") }
  let(:run)        { step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, agent_provider: workflow.agent_provider) }
  let(:handler)    { described_class.new(run) }
  let(:artifacts) do
    {
      "head_sha" => "abc1234567890",
      "failed_checks" => [
        {
          "name" => "rspec",
          "conclusion" => "failure",
          "details_url" => "https://example.test/checks/1"
        }
      ]
    }
  end

  around do |ex|
    Dir.mktmpdir("syrus-analyze-and-fix") do |dir|
      @ws_path = Pathname.new(dir)
      ex.run
    end
  end

  before do
    fake_ws = instance_double(WorkflowWorkspace, setup: nil, path: @ws_path)
    allow(handler).to receive(:workspace).and_return(fake_ws)
    allow(handler).to receive(:run_agent)
    allow(handler).to receive(:commit_agent_changes)
    allow(handler).to receive(:assert_branch_history_intact!)
    allow(handler).to receive(:diff_against_default).and_return("diff --git a/spec/foo_spec.rb b/spec/foo_spec.rb\n+bar")
    allow(handler).to receive(:diff_against_sha).and_return("diff --git a/spec/foo_spec.rb b/spec/foo_spec.rb\n+bar")
    allow(handler).to receive(:head_sha).and_return("def456")

    issue = Struct.new(:title, :body).new("Add greeting helper", "We need a greeting helper.")
    allow_any_instance_of(GithubClient).to receive(:fetch_issue).and_return(issue)
  end

  it "builds and persists the CI failure prompt" do
    handler.call

    expect(run.reload.prompt).to include("CI is failing on PR")
    expect(run.prompt).to include("syrus/issue-42-1")
    expect(run.prompt).to include("abc1234")
    expect(run.prompt).to include("rspec")
  end

  it "includes Epic context in the CI repair prompt" do
    epic = Factories.epic(
      user: user,
      repository: repository,
      title: "Syrus CLI and test planning",
      description: "Keep repair work aligned with the current child Job."
    )
    job.update!(epic: epic)

    handler.call

    expect(run.reload.prompt).to include("#{epic.slug}: Syrus CLI and test planning")
    expect(run.prompt).to include("Do not implement the entire Epic")
  end

  it "skips prompt rebuild when run.prompt is already set" do
    run.update!(prompt: "pre-set prompt content")

    expect(Prompts::CiFailure).not_to receive(:new)
    handler.call

    expect(run.reload.prompt).to eq("pre-set prompt content")
  end

  it "commits and captures the diff" do
    expect(handler).to receive(:commit_agent_changes)
      .with(a_string_starting_with("Fix CI: #{job.slug}:"))
    expect(handler).to receive(:assert_branch_history_intact!)

    handler.call

    expect(run.reload.agent_diff).to eq("diff --git a/spec/foo_spec.rb b/spec/foo_spec.rb\n+bar")
    expect(run.head_sha).to eq("def456")
  end

  it "records blocked_by_main when a no-op repair repeats a prior main-concern diagnosis" do
    allow(handler).to receive(:diff_against_sha).and_return("")
    prior_step = Step.create!(
      workflow: workflow,
      kind: "analyze_and_fix",
      position: 99,
      iteration: 0,
      loop_id: step.loop_id,
      state: "succeeded"
    )
    prior_run = prior_step.runs.create!(
      job: job,
      trigger_kind: workflow.trigger_kind,
      agent_provider: workflow.agent_provider,
      state: "succeeded",
      iteration: 0
    )
    MainConcernReport.create!(
      repository: repository,
      job: job,
      workflow: workflow,
      run: prior_run,
      observed_sha: "main123",
      failing_tests: [ "rspec-ci" ],
      reason: "rspec-ci fails the same way on origin/main"
    )
    MainConcernReport.create!(
      repository: repository,
      job: job,
      workflow: workflow,
      run: run,
      observed_sha: "main123",
      failing_tests: [ "rspec-ci" ],
      reason: "  RSpec-CI fails the same way on origin/main\n"
    )

    handler.call

    artifact = workflow.reload.artifact(CiRepair::NonActionableDiagnosis::ARTIFACT_KEY)
    expect(artifact).to include(
      "outcome" => "blocked_by_main",
      "run_id" => run.id,
      "prior_run_id" => prior_run.id,
      "observed_sha" => "main123",
      "failing_tests" => [ "rspec-ci" ]
    )
    expect(run.reload.step_agent_diff).to eq("")
    expect(run.agent_diff).to include("diff --git")
  end

  it "still raises NoChangesProduced when the whole branch has no diff and no repeated diagnosis" do
    allow(handler).to receive(:diff_against_default).and_return("")
    allow(handler).to receive(:diff_against_sha).and_return("")

    expect { handler.call }.to raise_error(Steps::Base::NoChangesProduced, "agent produced no changes")
  end

  context "prompt injector plugins" do
    after { Syrus::PluginRegistry.reset! }

    it "includes output from a registered prompt injector in the assembled prompt" do
      injector = Class.new do
        include Syrus::Plugin::PromptInjector
        def call(repository:, job:) = "Plugin-injected context: check the lockfile."
      end.new
      Syrus::PluginRegistry.register(:prompt_injector, injector)

      handler.call

      expect(run.reload.prompt).to include("Plugin-injected context: check the lockfile.")
    end

    it "passes the step's repository and job to the injector" do
      received = {}
      injector = Class.new do
        include Syrus::Plugin::PromptInjector
        attr_accessor :received
        def call(repository:, job:)
          self.received = { repository: repository, job: job }
          nil
        end
      end.new
      Syrus::PluginRegistry.register(:prompt_injector, injector)

      handler.call

      expect(injector.received[:repository]).to eq(job.repository)
      expect(injector.received[:job]).to eq(job)
    end

    it "skips injectors that return nil without raising" do
      Syrus::PluginRegistry.register(:prompt_injector, Class.new do
        include Syrus::Plugin::PromptInjector
        def call(repository:, job:) = nil
      end.new)

      expect { handler.call }.not_to raise_error
      expect(run.reload.prompt).to include("CI is failing on PR")
    end

    it "appends output from multiple injectors in registration order" do
      %w[Alpha Beta].each do |label|
        Syrus::PluginRegistry.register(:prompt_injector, Class.new do
          define_method(:call) { |repository:, job:| "Injected by #{label}" }
          include Syrus::Plugin::PromptInjector
        end.new)
      end

      handler.call

      prompt = run.reload.prompt
      expect(prompt.index("Injected by Alpha")).to be < prompt.index("Injected by Beta")
    end
  end
end
