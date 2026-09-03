require "rails_helper"
require "tmpdir"

# End-to-end check that a prepare command still produces an sccache capture now
# that the path runs through a domain event and a plugin subscriber rather than
# a hardcoded call in Steps::Base.
RSpec.describe "build_cache capture during Steps::Prepare" do
  let(:job)      { Factories.job }
  let(:workflow) { job.workflows.last }
  let(:step)     { workflow.steps.first.tap { |s| s.update!(kind: "prepare") } }
  let(:run)      { step.runs.first || step.runs.create!(job: job, trigger_kind: workflow.trigger_kind) }
  let(:handler)  { Steps::Prepare.new(run) }

  around do |ex|
    Dir.mktmpdir("syrus-build-cache-prepare") do |dir|
      @ws_path = Pathname.new(dir)
      ex.run
    end
  end

  before do
    fake_ws = instance_double(WorkflowWorkspace, setup: nil, path: @ws_path)
    allow(handler).to receive(:workspace).and_return(fake_ws)
    File.write(@ws_path.join(".syrus.yml"), "prepare:\n  - echo first\n")
  end

  it "records one artifact entry per prepare command when sccache reports stats" do
    allow(BuildCache::StatsCapture).to receive(:capture).and_return({ "compile_requests" => 3 })

    handler.call

    entries = workflow.reload.artifact("sccache_stats")
    expect(entries.size).to eq(1)
    expect(entries.first).to include(
      "step_kind" => "prepare",
      "label" => "echo first",
      "stats" => { "compile_requests" => 3 }
    )
  end

  it "records nothing when sccache is not installed" do
    allow(BuildCache::StatsCapture).to receive(:capture).and_return(nil)

    handler.call

    expect(workflow.reload.artifact("sccache_stats")).to be_nil
  end

  it "records nothing when the plugin is disabled" do
    allow(BuildCache::StatsCapture).to receive(:capture).and_return({ "compile_requests" => 3 })
    PluginRecord.find_or_create_by!(name: "build_cache").update!(enabled: false, disableable: true)

    handler.call

    expect(workflow.reload.artifact("sccache_stats")).to be_nil
  end
end
