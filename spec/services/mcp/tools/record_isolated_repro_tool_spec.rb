require "rails_helper"
require "tmpdir"
require "fileutils"

RSpec.describe Mcp::Tools::RecordIsolatedReproTool do
  let(:job) { Factories.job }
  let(:workflow) { job.workflows.last }
  let(:fix_run) { job.initial_run }

  let!(:grader_step) do
    Step.create!(
      workflow: workflow, kind: "grader", position: 50, iteration: 1, state: "failed",
      details: { "name" => "rspec", "required" => true }
    )
  end
  let!(:grader_run) { grader_step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, state: "failed", iteration: 1) }

  let(:provider) do
    Module.new do
      class << self
        attr_accessor :recorded
      end

      define_singleton_method(:failed_test_cases) do |run:, grader_name:|
        [ { "suite_name" => "spec/foo_spec.rb", "name" => "does the thing" } ]
      end

      define_singleton_method(:record_isolated_repro!) do |**kwargs|
        self.recorded = kwargs
        nil
      end
    end
  end

  around do |example|
    Dir.mktmpdir("syrus-record-isolated-repro") do |dir|
      @repo_dir = dir
      git("init", "-q")
      git("config", "user.email", "agent@example.com")
      git("config", "user.name", "Agent")
      File.write(File.join(@repo_dir, "README.md"), "hello")
      git("add", "README.md")
      git("commit", "-q", "-m", "initial commit")
      @failing_sha = git("rev-parse", "HEAD").strip
      example.run
    end
  end

  def git(*args)
    output = IO.popen([ "git", "-C", @repo_dir, *args ], err: [ :child, :out ], &:read)
    raise "git #{args.join(' ')} failed: #{output}" unless $?.success?

    output
  end

  before do
    workflow.set_artifact!(GraderConclusionCache::ARTIFACT_HEAD_SHA_KEY, @failing_sha)
    allow(WorkflowWorkspace).to receive(:path_for).with(workflow).and_return(Pathname.new(@repo_dir))
    allow(Syrus::PluginRegistry).to receive(:providers_for).and_call_original
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:test_evidence).and_return([ provider ])
  end

  def call(**overrides)
    described_class.call(
      grader_name: "rspec",
      suite_name: "spec/foo_spec.rb",
      name: "does the thing",
      reproduced: false,
      command: "bundle exec rspec spec/foo_spec.rb -e 'does the thing'",
      output: "1 example, 0 failures",
      exit_status: 0,
      server_context: { run: fix_run },
      **overrides
    )
  end

  it "exposes the expected tool name and required schema" do
    expect(described_class.tool_name).to eq("record_isolated_repro")
    expect(described_class.input_schema_value.to_h[:required]).to eq(
      %w[grader_name suite_name name reproduced command output]
    )
  end

  it "records the exact command, raw output, and verdict as a structured, auditable record" do
    response = call

    expect(response).not_to be_error
    expect(provider.recorded).to include(
      grader_name: "rspec",
      suite_name: "spec/foo_spec.rb",
      name: "does the thing",
      sha: @failing_sha,
      reproduced: false,
      command: "bundle exec rspec spec/foo_spec.rb -e 'does the thing'",
      output: "1 example, 0 failures",
      exit_status: 0
    )
  end

  it "writes a JobLog audit line" do
    expect { call }.to change { fix_run.job_logs.count }.by(1)
    expect(fix_run.job_logs.last.chunk).to include("[mcp] record_isolated_repro")
  end

  it "rejects a repro attempt recorded after the agent's own fix commits exist (workspace HEAD has moved)" do
    File.write(File.join(@repo_dir, "fix.txt"), "a fix")
    git("add", "fix.txt")
    git("commit", "-q", "-m", "fix attempt")

    response = call

    expect(response).to be_error
    expect(response.content.first[:text]).to match(/no longer matches the last graded SHA/)
    expect(provider.recorded).to be_nil
  end

  it "rejects a repro attempt for a test that was not actually reported as failing" do
    response = call(name: "a completely different example")

    expect(response).to be_error
    expect(response.content.first[:text]).to match(/not among the currently failing tests/)
    expect(provider.recorded).to be_nil
  end

  it "rejects when there is no known failing SHA for the workflow" do
    workflow.set_artifact!(GraderConclusionCache::ARTIFACT_HEAD_SHA_KEY, nil)

    response = call

    expect(response).to be_error
    expect(response.content.first[:text]).to match(/no known failing grade SHA/)
  end
end
