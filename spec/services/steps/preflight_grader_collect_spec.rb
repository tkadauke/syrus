require "rails_helper"
require "tmpdir"

RSpec.describe Steps::PreflightGraderCollect do
  let(:job)      { Factories.job }
  let(:workflow) { job.workflows.last }

  let(:step) do
    Step.create!(
      workflow: workflow,
      kind: "preflight_grader_collect",
      position: 102,
      iteration: 1
    )
  end

  let(:run) { step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, state: "running", iteration: step.iteration) }
  let(:handler) { described_class.new(run) }

  around do |example|
    Dir.mktmpdir("syrus-preflight-collect") do |dir|
      @ws_path = Pathname.new(dir)
      example.run
    end
  end

  before do
    fake_ws = instance_double(WorkflowWorkspace, path: @ws_path)
    allow(handler).to receive(:workspace).and_return(fake_ws)
  end

  def create_preflight_grader(name:, required:, state:)
    Step.create!(
      workflow: workflow,
      kind: "preflight_grader",
      position: 101,
      iteration: 1,
      state: state,
      details: { "name" => name, "required" => required }
    )
  end

  def create_downstream_steps
    [
      Step.create!(workflow: workflow, kind: "implement",      position: 103, iteration: 1, next_step_id: nil),
      Step.create!(workflow: workflow, kind: "grader_fanout",  position: 104, iteration: 1, next_step_id: nil),
      Step.create!(workflow: workflow, kind: "grader_collect", position: 105, iteration: 1, next_step_id: nil),
      Step.create!(workflow: workflow, kind: "summarize",      position: 106, iteration: 1, next_step_id: nil),
      Step.create!(workflow: workflow, kind: "pr_open",        position: 107, iteration: 1, next_step_id: nil)
    ].tap do |steps|
      step.update!(next_step_id: steps.first.id)
      steps.each_cons(2) { |a, b| a.update!(next_step_id: b.id) }
    end
  end

  context "when all required preflight graders passed" do
    before do
      create_preflight_grader(name: "rspec",  required: true,  state: "succeeded")
      create_preflight_grader(name: "rubocop", required: false, state: "failed")
      create_downstream_steps
    end

    it "sets the preflight_passed workflow artifact" do
      handler.call

      expect(workflow.reload.artifact("preflight_passed")).to be true
    end

    it "cancels all downstream steps" do
      downstream = create_downstream_steps

      handler.call

      cancelled_kinds = downstream.map { |s| s.reload.state }
      expect(cancelled_kinds).to all(eq("cancelled"))
    end

    it "does not raise StepFailed" do
      expect { handler.call }.not_to raise_error
    end

    it "logs a message indicating preflight passed" do
      handler.call

      log_text = run.reload.job_logs.pluck(:chunk).join
      expect(log_text).to include("all required graders passed")
      expect(log_text).to include("skipping implement")
    end
  end

  context "when a required preflight grader failed" do
    before do
      create_preflight_grader(name: "rspec", required: true, state: "failed")
      create_downstream_steps
    end

    it "does not set the preflight_passed artifact" do
      handler.call

      expect(workflow.reload.artifact("preflight_passed")).to be_nil
    end

    it "does not cancel downstream steps" do
      downstream = create_downstream_steps

      handler.call

      states = downstream.map { |s| s.reload.state }
      expect(states).to all(eq("queued"))
    end

    it "does not raise StepFailed" do
      expect { handler.call }.not_to raise_error
    end

    it "logs the failing grader name" do
      handler.call

      log_text = run.reload.job_logs.pluck(:chunk).join
      expect(log_text).to include("rspec")
      expect(log_text).to include("proceeding to implement")
    end
  end

  context "when no preflight grader steps exist (no graders configured)" do
    it "sets the preflight_passed artifact" do
      handler.call

      expect(workflow.reload.artifact("preflight_passed")).to be true
    end

    it "cancels downstream steps" do
      downstream = create_downstream_steps

      handler.call

      expect(downstream.map { |s| s.reload.state }).to all(eq("cancelled"))
    end
  end

  context "when only non-required graders failed" do
    before do
      create_preflight_grader(name: "rspec",   required: true,  state: "succeeded")
      create_preflight_grader(name: "optional", required: false, state: "failed")
    end

    it "sets preflight_passed since no required graders failed" do
      handler.call

      expect(workflow.reload.artifact("preflight_passed")).to be true
    end
  end
end
