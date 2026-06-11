require "rails_helper"
require "tmpdir"

RSpec.describe Steps::GraderCollect do
  let(:job) { Factories.job }
  let(:workflow) { job.workflows.last }
  let(:loop_id) { SecureRandom.uuid }
  let(:step) do
    Step.create!(
      workflow: workflow,
      kind: "grader_collect",
      position: 101,
      iteration: 1,
      loop_id: loop_id
    )
  end
  let(:run) { step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, state: "running", iteration: step.iteration) }
  let(:handler) { described_class.new(run) }

  around do |example|
    Dir.mktmpdir("syrus-grader-collect") do |dir|
      @ws_path = Pathname.new(dir)
      example.run
    end
  end

  before do
    Step.create!(
      workflow: workflow,
      kind: "grader",
      position: 100,
      iteration: 1,
      loop_id: loop_id,
      state: "succeeded",
      details: { "name" => "tests", "required" => true }
    )
    fake_ws = instance_double(WorkflowWorkspace, path: @ws_path)
    git = instance_double(GitRunner, run: "abc123\n")
    allow(handler).to receive(:workspace).and_return(fake_ws)
    allow(GitRunner).to receive(:new).and_return(git)
  end

  it "records a reusable validation artifact when required graders pass" do
    handler.call

    expect(workflow.reload.artifact(LandingValidationCache::ARTIFACT_KEY)).to include(
      "required_graders_passed" => true,
      "head_sha" => "abc123"
    )
  end
end
