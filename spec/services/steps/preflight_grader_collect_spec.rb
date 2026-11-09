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

    it "repairs an already-skipped grade-loop barrier when the successful preflight is replayed" do
      downstream = create_downstream_steps_with_retry_until_loop
      grader_collect = downstream.find { |s| s.kind == "grader_collect" }
      downstream.each { |candidate| candidate.skip! if candidate.may_skip? }

      expect(workflow.reload).to be_uncleared_retry_until_barrier

      handler.call

      expect(grader_collect.reload).to be_retry_until_barrier_superseded
      expect(workflow.reload).not_to be_uncleared_retry_until_barrier
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

  context "when a required preflight grader reproducibly failed" do
    let(:failure_details) do
      { "command" => "bin/rspec", "exit_code" => 1, "output" => "expected: true\n     got: false\n" }
    end

    before do
      create_preflight_grader(name: "rspec", required: true, state: "failed", details: failure_details)
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

    it "records exact command, exit metadata, outcome and durable references for the implement prompt" do
      workflow.steps.where(kind: "preflight_grader").delete_all
      grader = create_preflight_grader(
        name: "rspec-ci",
        required: true,
        state: "failed",
        details: {
          "command" => "bin/rspec-ci",
          "capabilities" => { "os" => [ "linux" ] },
          "exit_code" => 1,
          "duration_s" => 12.3,
          "timed_out" => false,
          "log_path" => ".syrus/grade-output/preflight/rspec-ci.log",
          "log_bytes" => 2048,
          "junit_output" => "tmp/junit.xml",
          "output" => "expected: true\n     got: false\n"
        }
      )
      grader_run = grader.runs.create!(job: job, trigger_kind: workflow.trigger_kind, state: "failed", iteration: 1)
      allow(TestEvidenceLookup).to receive(:failed_test_cases_for).with(grader_run, "rspec-ci")
        .and_return([ { "identity" => "spec/models/foo_spec.rb[1:1]", "name" => "foo" } ])

      handler.call

      expect(workflow.reload.artifact("preflight_failures")).to eq([
        {
          "name" => "rspec-ci",
          "command" => "bin/rspec-ci",
          "capabilities" => { "os" => [ "linux" ] },
          "required" => true,
          "status" => "failed",
          "outcome" => "test_failed",
          "outcome_reason" => "nonzero_exit_with_evidence",
          "exit_code" => 1,
          "duration_s" => 12.3,
          "timed_out" => false,
          "log_path" => ".syrus/grade-output/preflight/rspec-ci.log",
          "log_bytes" => 2048,
          "junit_output" => "tmp/junit.xml",
          "failed_tests" => [ "spec/models/foo_spec.rb[1:1]" ],
          "step_id" => grader.id,
          "run_id" => grader_run.id,
          "output" => "expected: true\n     got: false\n"
        }
      ])
    end

    it "stays inconclusive and skips the repair when another required grader exhausted its infrastructure retries" do
      create_preflight_grader(
        name: "lint", required: true, state: "failed",
        details: { "command" => "bin/lint", "exit_code" => nil, "outcome" => "infrastructure_failed", "outcome_reason" => "worker_died",
                   "infrastructure_retry_attempt" => PreflightGraderPolicy.retry_budget }
      )
      downstream = create_downstream_steps

      handler.call

      expect(workflow.reload.artifact("preflight_failures")).to be_nil
      expect(workflow.artifact("preflight_inconclusive").map { |entry| entry["name"] }).to contain_exactly("rspec", "lint")
      expect(downstream.map { |candidate| candidate.reload.state }).to all(eq("skipped"))
    end
  end

  context "when a passing-looking grader failed without transport metadata" do
    it "never enters the agent prompt as a code failure" do
      create_preflight_grader(name: "rspec", required: true, state: "failed", details: { "command" => "bin/rspec", "output" => "0 failures" })
      downstream = create_downstream_steps

      handler.call

      expect(workflow.reload.artifact("preflight_failures")).to be_nil
      expect(workflow.artifact("preflight_inconclusive").map { |entry| entry["outcome"] }).to eq([ "inconclusive" ])
      expect(downstream.map { |candidate| candidate.reload.state }).to all(eq("skipped"))
    end
  end

  [ "cancelled", "blocked", "skipped" ].each do |terminal_state|
    context "when a required preflight grader is #{terminal_state}" do
      before do
        create_preflight_grader(name: "rspec", required: true, state: terminal_state)
      end

      it "stays inconclusive without spawning a coding repair because main was not proven broken" do
        downstream = create_downstream_steps

        expect { handler.call }.not_to raise_error

        expect(workflow.reload.artifact("preflight_passed")).to be_nil
        expect(workflow.artifact("preflight_failures")).to be_nil
        expect(workflow.artifact("preflight_inconclusive")).to contain_exactly(
          include("name" => "rspec", "required" => true, "status" => terminal_state)
        )
        expect(downstream.map { |candidate| candidate.reload.state }).to all(eq("skipped"))
        expect(run.reload.job_logs.pluck(:chunk).join).to include("rspec", "not spawning a coding repair")
      end
    end
  end

  context "when a required preflight grader hit an infrastructure failure" do
    let!(:failed_grader) do
      create_preflight_grader(
        name: "rspec", required: true, state: "failed",
        details: { "command" => "bin/rspec", "exit_code" => nil, "outcome" => "infrastructure_failed", "outcome_reason" => "worker_died",
                   "output" => "boom", "worker" => "worker-1", "infrastructure_retry_attempt" => 0 }
      )
    end
    let!(:downstream) { create_downstream_steps }

    it "re-runs only that grader on a fresh Step with a replacement collector, without failing the workflow" do
      expect { handler.call }.not_to raise_error

      retry_step = workflow.steps.where(kind: "preflight_grader").where.not(id: failed_grader.id).sole
      expect(retry_step.details).to include(
        "name" => "rspec", "command" => "bin/rspec", "infrastructure_retry_attempt" => 1,
        "retry_of_step_id" => failed_grader.id, "previous_worker" => "worker-1"
      )
      expect(retry_step.details.keys).not_to include("exit_code", "outcome", "output")
      expect(retry_step).to be_queued

      replacement = workflow.steps.where(kind: "preflight_grader_collect").where.not(id: step.id).sole
      expect(step.reload.next_step_id).to eq(retry_step.id)
      expect(retry_step.next_step_id).to eq(replacement.id)
      expect(replacement.next_step_id).to eq(downstream.first.id)
      expect(replacement.depends_on_step_ids).to eq([ retry_step.id ])
      expect(replacement.position).to be < downstream.first.reload.position
      expect(downstream.map { |candidate| candidate.reload.state }).to all(eq("queued"))
      expect(workflow.artifact("preflight_failures")).to be_nil
      expect(workflow.artifact("preflight_inconclusive")).to be_nil
    end

    it "judges the retried grader, not the superseded one, once the replacement collector runs" do
      handler.call
      retry_step = workflow.steps.where(kind: "preflight_grader").where.not(id: failed_grader.id).sole
      retry_step.update!(state: "succeeded")

      replacement = workflow.steps.where(kind: "preflight_grader_collect").where.not(id: step.id).sole
      replacement_run = replacement.runs.create!(job: job, trigger_kind: workflow.trigger_kind, state: "running", iteration: 1)
      replacement_handler = described_class.new(replacement_run)
      allow(replacement_handler).to receive(:workspace).and_return(instance_double(WorkflowWorkspace, path: @ws_path))
      replacement_handler.call

      expect(workflow.reload.artifact("preflight_passed")).to be true
    end

    it "does not retry past the budget; exhausted retries are inconclusive and never reach the agent" do
      failed_grader.update!(details: failed_grader.details.merge("infrastructure_retry_attempt" => PreflightGraderPolicy.retry_budget))

      handler.call

      expect(workflow.steps.where(kind: "preflight_grader").count).to eq(1)
      expect(workflow.reload.artifact("preflight_failures")).to be_nil
      expect(workflow.artifact("preflight_inconclusive")).to contain_exactly(
        include("name" => "rspec", "outcome" => "infrastructure_failed", "outcome_reason" => "worker_died")
      )
      expect(downstream.map { |candidate| candidate.reload.state }).to all(eq("skipped"))
    end

    it "retries one lock timeout among 100+ graders without touching the other graders" do
      120.times { |index| create_preflight_grader(name: "g#{index}", required: true, state: "succeeded") }

      handler.call

      expect(workflow.steps.where(kind: "preflight_grader").where(state: "queued").count).to eq(1)
      expect(workflow.reload.artifact("preflight_passed")).to be_nil
      expect(workflow.artifact("preflight_inconclusive")).to be_nil
    end
  end

  context "when a genuine assertion failure exists" do
    it "is never retried as infrastructure" do
      create_preflight_grader(name: "rspec", required: true, state: "failed",
                              details: { "command" => "bin/rspec", "exit_code" => 1, "output" => "1 failure" })
      create_downstream_steps

      handler.call

      expect(workflow.steps.where(kind: "preflight_grader").count).to eq(1)
      expect(workflow.steps.where(kind: "preflight_grader_collect").count).to eq(1)
    end
  end

  context "when no preflight grader steps exist (no graders configured)" do
    it "does not set the preflight_passed artifact" do
      handler.call

      expect(workflow.reload.artifact("preflight_passed")).to be_nil
    end

    it "does not skip downstream steps" do
      downstream = create_downstream_steps

      handler.call

      expect(downstream.map { |s| s.reload.state }).to all(eq("queued"))
    end

    it "logs that repair should continue through implement" do
      handler.call

      log_text = run.reload.job_logs.pluck(:chunk).join
      expect(log_text).to include("no preflight graders ran")
      expect(log_text).to include("proceeding to implement")
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
