require "rails_helper"
require "tmpdir"

RSpec.describe Steps::PreflightGrader do
  let(:job) { Factories.job }
  let(:workflow) { Workflow.create!(job: job, trigger_kind: "main_branch_repair") }
  let(:step) do
    Step.create!(workflow: workflow, kind: "preflight_grader", position: 101, iteration: 1,
                 details: { "name" => "rspec", "command" => "bin/rspec" })
  end
  let(:run) { step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, state: "running", iteration: 1) }
  let(:handler) { described_class.new(run) }

  around do |example|
    Dir.mktmpdir("syrus-preflight-grader") do |dir|
      @ws_path = Pathname.new(dir)
      example.run
    end
  end

  before do
    allow(handler).to receive(:workspace).and_return(instance_double(WorkflowWorkspace, path: @ws_path))
  end

  def namespaced_files
    FileUtils.mkdir_p(@ws_path.join("storage"))
    ns = PreflightGraderPolicy.database_namespace(step)
    [ @ws_path.join("storage/test#{ns}.sqlite3"), @ws_path.join("storage/test_search#{ns}.sqlite3-wal") ].each { |f| File.write(f, "x") }
  end

  it "gives the grader command its own test database namespace" do
    allow(handler).to receive(:workspace_dependency_env).and_return({})
    allow(Steps::Prepare).to receive(:prep_extra_env).and_return({})
    allow(handler).to receive(:resource_grant_env).and_return({})
    allow(handler).to receive(:previous_failure_env).and_return({})

    env = handler.send(:env)

    expect(env["TEST_ENV_NUMBER"]).to eq("pf#{step.id}")
    expect(env["SEARCH_DATABASE_PATH"]).to eq("storage/test_searchpf#{step.id}.sqlite3")
  end

  it "removes its database files even when the grader fails" do
    files = namespaced_files
    other = @ws_path.join("storage/testpf999999.sqlite3").tap { |f| File.write(f, "x") }
    failing_workspace = instance_double(WorkflowWorkspace, path: @ws_path)
    allow(failing_workspace).to receive(:setup).and_raise(Steps::Base::StepFailed, "boom")
    allow(handler).to receive(:workspace).and_return(failing_workspace)

    expect { handler.call }.to raise_error(Steps::Base::StepFailed)

    expect(files.none?(&:exist?)).to be(true)
    expect(other).to exist
  end
end
