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

  def create_preflight_grader(name:, required:, state:, details: {})
    Step.create!(
      workflow: workflow,
      kind: "preflight_grader",
      position: 101,
      iteration: 1,
      state: state,
      details: {
        "name" => name,
        "required" => required
      }.merge(details)
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

  # Mirrors the real retry_until loop shape (Workflows::Base.materialize_steps!):
  # implement/grader_fanout/grader_collect share one loop_id, the way
  # grader_retry_loop materializes them.
  def create_downstream_steps_with_retry_until_loop
    loop_id = SecureRandom.uuid
    [
      Step.create!(workflow: workflow, kind: "implement",      position: 103, iteration: 1, loop_id: loop_id, next_step_id: nil),
      Step.create!(workflow: workflow, kind: "grader_fanout",  position: 104, iteration: 1, loop_id: loop_id, next_step_id: nil),
      Step.create!(workflow: workflow, kind: "grader_collect", position: 105, iteration: 1, loop_id: loop_id, next_step_id: nil),
      Step.create!(workflow: workflow, kind: "summarize",      position: 106, iteration: 1, next_step_id: nil),
      Step.create!(workflow: workflow, kind: "test_plan",      position: 107, iteration: 1, next_step_id: nil),
      Step.create!(workflow: workflow, kind: "pr_open",        position: 108, iteration: 1, next_step_id: nil)
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

    it "skips all downstream steps" do
      downstream = create_downstream_steps

      handler.call

      skipped_kinds = downstream.map { |s| s.reload.state }
      expect(skipped_kinds).to all(eq("skipped"))
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

    it "marks the skipped grade-loop retry_until barrier as superseded so the workflow can still succeed" do
      downstream = create_downstream_steps_with_retry_until_loop
      grader_collect = downstream.find { |s| s.kind == "grader_collect" }

      handler.call

      expect(grader_collect.reload).to be_skipped
      expect(grader_collect.retry_until_barrier_superseded?).to be true
      expect(workflow.reload.uncleared_retry_until_barrier?).to be false
    end

    it "does not mark non-barrier downstream steps as retry_until_barrier_superseded" do
      downstream = create_downstream_steps_with_retry_until_loop
      implement = downstream.find { |s| s.kind == "implement" }
      summarize = downstream.find { |s| s.kind == "summarize" }

      handler.call

      expect(implement.reload.retry_until_barrier_superseded?).to be false
      expect(summarize.reload.retry_until_barrier_superseded?).to be false
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

    it "records failed preflight command context for the implement prompt" do
      workflow.steps.where(kind: "preflight_grader").delete_all
      create_preflight_grader(
        name: "rspec-ci",
        required: true,
        state: "failed",
        details: {
          "command" => "bin/rspec-ci",
          "exit_code" => 1,
          "duration_s" => 12.3,
          "timed_out" => false,
          "log_path" => ".syrus/grade-output/preflight/rspec-ci.log",
          "log_bytes" => 2048,
          "output" => "expected: true\n     got: false\n"
        }
      )

      handler.call

      expect(workflow.reload.artifact("preflight_failures")).to eq([
        {
          "name" => "rspec-ci",
          "command" => "bin/rspec-ci",
          "required" => true,
          "status" => "failed",
          "exit_code" => 1,
          "duration_s" => 12.3,
          "timed_out" => false,
          "log_path" => ".syrus/grade-output/preflight/rspec-ci.log",
          "log_bytes" => 2048,
          "output" => "expected: true\n     got: false\n"
        }
      ])
    end
  end

  context "when no preflight grader steps exist (no graders configured)" do
    it "sets the preflight_passed artifact" do
      handler.call

      expect(workflow.reload.artifact("preflight_passed")).to be true
    end

    it "skips downstream steps" do
      downstream = create_downstream_steps

      handler.call

      expect(downstream.map { |s| s.reload.state }).to all(eq("skipped"))
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
