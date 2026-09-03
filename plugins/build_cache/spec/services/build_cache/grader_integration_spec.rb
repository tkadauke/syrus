require "rails_helper"
require "tmpdir"

RSpec.describe "build_cache capture during Steps::Grader", :ci_only do
  let(:job) { Factories.job }
  let(:workflow) { job.workflows.last }
  let(:step) do
    Step.create!(
      workflow: workflow,
      kind: "grader",
      position: 99,
      details: {
        "name" => "tests",
        "command" => "ruby -e 'puts \"durable output\"'",
        "required" => true,
        "timeout_minutes" => 1
      }
    )
  end
  let(:run) { step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, state: "running", iteration: step.iteration) }
  let(:handler) { Steps::Grader.new(run) }

  around do |example|
    old_data_root = ENV["SYRUS_DATA_ROOT"]
    Dir.mktmpdir("syrus-grader") do |dir|
      ENV["SYRUS_DATA_ROOT"] = dir
      example.run
    end
  ensure
    ENV["SYRUS_DATA_ROOT"] = old_data_root
  end

  before do
    # Computed here, not in the `around` block above: `workflow` memoizes
    # `Factories.job`, which validates User#agent_provider against
    # Syrus::PluginRegistry-registered providers. The registry is reset at
    # boot in test env and only repopulated by spec/support/bundled_plugins.rb's
    # global `before` hook, which — like every other `before` hook — only runs
    # once `around` calls `example.run`. Resolving `workflow` before that call
    # (i.e. still inside `around`) raced ahead of that repopulation and made
    # every example in this file fail with "Agent provider is not included in
    # the list" whenever the registry hadn't already been populated by an
    # earlier example in the same process.
    @ws_path = WorkflowWorkspace.path_for(workflow)
    fake_ws = instance_double(WorkflowWorkspace, setup: nil, path: @ws_path)
    allow(handler).to receive(:workspace).and_return(fake_ws)
  end

  describe "sccache stats capture" do
    it "records a workflow artifact entry named after the grader when sccache reports stats" do
      allow(BuildCache::StatsCapture).to receive(:capture).and_return({ "compile_requests" => 5 })

      handler.call

      entries = workflow.reload.artifact("sccache_stats")
      expect(entries.size).to eq(1)
      expect(entries.first).to include("step_kind" => "grader", "label" => "tests", "stats" => { "compile_requests" => 5 })
    end

    it "does not record an artifact when sccache isn't installed" do
      allow(BuildCache::StatsCapture).to receive(:capture).and_return(nil)

      handler.call

      expect(workflow.reload.artifact("sccache_stats")).to be_nil
    end
  end
end
