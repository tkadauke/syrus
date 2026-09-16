require "rails_helper"
require "tmpdir"

RSpec.describe IsolatedReproRecorder do
  let(:repository) { Factories.repository }
  let(:job) { Factories.job(repository: repository) }
  let(:workflow) { job.workflows.last }
  let(:sha) { "c" * 40 }

  let!(:grader_step) do
    Step.create!(
      workflow: workflow, kind: "grader", position: 50, iteration: 1, state: "failed",
      details: { "name" => "rspec", "required" => true }
    )
  end
  let!(:grader_run) { grader_step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, state: "failed", iteration: 1) }

  let!(:fix_step) { Step.create!(workflow: workflow, kind: "landing_fix", position: 51, iteration: 1) }
  let(:fix_run) { fix_step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, state: "running", iteration: 1) }

  let(:provider) do
    Module.new do
      class << self
        attr_accessor :recorded_args
      end

      define_singleton_method(:failed_test_cases) do |run:, grader_name:|
        [ { "suite_name" => "spec/foo_spec.rb", "name" => "does the thing" } ]
      end

      define_singleton_method(:record_isolated_repro!) do |**kwargs|
        self.recorded_args = kwargs
        nil
      end
    end
  end

  around do |example|
    Dir.mktmpdir("syrus-isolated-repro") do |dir|
      @ws_path = Pathname.new(dir)
      example.run
    end
  end

  before do
    workflow.set_artifact!(GraderConclusionCache::ARTIFACT_HEAD_SHA_KEY, sha)
    allow(WorkflowWorkspace).to receive(:path_for).with(workflow).and_return(@ws_path)
    git = instance_double(GitRunner, run: "#{sha}\n")
    allow(GitRunner).to receive(:new).and_return(git)
    allow(Syrus::PluginRegistry).to receive(:providers_for).and_call_original
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:test_evidence).and_return([ provider ])
  end

  def call(**overrides)
    described_class.call(
      run: fix_run,
      grader_name: "rspec",
      suite_name: "spec/foo_spec.rb",
      name: "does the thing",
      reproduced: false,
      command: "bundle exec rspec spec/foo_spec.rb -e 'does the thing'",
      output: "1 example, 0 failures",
      exit_status: 0,
      **overrides
    )
  end

  it "records a valid pre-fix same-SHA non-reproduction and returns the evidence" do
    result = call

    expect(result).to be_ok
    expect(provider.recorded_args).to include(
      repository: repository,
      grader_name: "rspec",
      suite_name: "spec/foo_spec.rb",
      name: "does the thing",
      sha: sha,
      reproduced: false,
      command: "bundle exec rspec spec/foo_spec.rb -e 'does the thing'",
      output: "1 example, 0 failures",
      exit_status: 0
    )
    expect(result.evidence).to include(sha: sha, reproduced: false)
  end

  it "rejects a repro attempt whose workspace HEAD no longer matches the graded SHA (e.g. after a fix commit)" do
    git = instance_double(GitRunner, run: "#{'d' * 40}\n")
    allow(GitRunner).to receive(:new).and_return(git)

    result = call

    expect(result).not_to be_ok
    expect(result.error).to match(/no longer matches the last graded SHA/)
    expect(provider.recorded_args).to be_nil
  end

  it "rejects when there is no known failing SHA recorded for the workflow yet" do
    workflow.set_artifact!(GraderConclusionCache::ARTIFACT_HEAD_SHA_KEY, nil)

    result = call

    expect(result).not_to be_ok
    expect(result.error).to match(/no known failing grade SHA/)
    expect(provider.recorded_args).to be_nil
  end

  it "rejects a test that is not among the grader's currently failing tests" do
    result = call(name: "an entirely different example")

    expect(result).not_to be_ok
    expect(result.error).to match(/not among the currently failing tests/)
    expect(provider.recorded_args).to be_nil
  end

  it "rejects when no failed grader Step matches the given grader_name" do
    result = call(grader_name: "eslint")

    expect(result).not_to be_ok
    expect(result.error).to match(/no failed grader Step named "eslint"/)
  end

  it "rejects a blank command" do
    result = call(command: "   ")

    expect(result).not_to be_ok
    expect(result.error).to match(/command is required/)
    expect(provider.recorded_args).to be_nil
  end
end
