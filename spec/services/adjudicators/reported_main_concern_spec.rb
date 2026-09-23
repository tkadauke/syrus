require "rails_helper"

RSpec.describe Adjudicators::ReportedMainConcern do
  let(:job) { Factories.job }
  let(:workflow) { job.workflows.first }
  let(:loop_id) { SecureRandom.uuid }
  let(:grader_step) do
    Step.create!(
      workflow: workflow,
      kind: "grader",
      position: 10,
      iteration: 2,
      loop_id: loop_id,
      state: "failed",
      details: {
        "name" => "work-engine-simulations",
        "required" => true,
        "failures" => "allow_inherited",
        "command" => "bin/simulator",
        "base_retry" => { "strategy" => "full_command" }
      }
    )
  end

  def repair_run_for_grader_step(kind: "landing_fix")
    repair_step = Step.create!(
      workflow: workflow,
      kind: kind,
      position: 9,
      iteration: grader_step.iteration,
      loop_id: loop_id
    )
    repair_step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, state: "succeeded", iteration: grader_step.iteration)
  end

  def adjudicate(base_sha: "base123")
    described_class.adjudicate(problem: Problem[:grader_failure], workflow: workflow, step: [ grader_step ], base_sha: base_sha)
  end

  before do
    allow(Syrus::PluginRegistry).to receive(:providers_for).and_call_original
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:test_evidence).and_return([])
  end

  it "declines for a problem that is not a grader failure" do
    expect(described_class.adjudicate(problem: Problem[:timeout], workflow: workflow)).to be_inconclusive
  end

  it "declines when there is no workflow to reason about" do
    expect(described_class.adjudicate(problem: Problem[:grader_failure])).to be_inconclusive
  end

  it "declines when no report_main_concern was filed for this iteration" do
    verdict = adjudicate

    expect(verdict).to be_inconclusive
    expect(verdict.reason).to eq("no_main_concern_reported")
  end

  it "declines when report_main_concern was filed for a different iteration" do
    other_repair = Step.create!(workflow: workflow, kind: "landing_fix", position: 8, iteration: 1, loop_id: loop_id)
    other_run = other_repair.runs.create!(job: job, trigger_kind: workflow.trigger_kind, state: "succeeded", iteration: 1)
    MainConcernReport.create!(repository: job.repository, job: job, workflow: workflow, run: other_run, reason: "unrelated iteration")

    verdict = adjudicate

    expect(verdict).to be_inconclusive
    expect(verdict.reason).to eq("no_main_concern_reported")
  end

  it "declines under strict failure policy even with a report and a matching base retry" do
    grader_step.update!(details: grader_step.details.merge("failures" => "strict"))
    run = repair_run_for_grader_step
    MainConcernReport.create!(repository: job.repository, job: job, workflow: workflow, run: run, reason: "looks pre-existing")
    allow(BaseRevisionRetry).to receive(:call)

    verdict = adjudicate

    expect(verdict).to be_inconclusive
    expect(verdict.reason).to eq("strict_failure_policy")
    expect(BaseRevisionRetry).not_to have_received(:call)
  end

  it "declines when the base-revision retry shows the base revision passing" do
    run = repair_run_for_grader_step
    MainConcernReport.create!(repository: job.repository, job: job, workflow: workflow, run: run, reason: "looks pre-existing")
    allow(BaseRevisionRetry).to receive(:call).and_return(
      BaseRevisionRetry::Result.new(
        ran: true, inherited: false, reason: "base_retry_full_command_base_passed",
        command: "bin/simulator", base_failed_identities: [], introduced_failed_identities: [], output: ""
      )
    )

    verdict = adjudicate

    expect(verdict).to be_inconclusive
    expect(verdict.reason).to eq("base_retry_not_confirmed")
  end

  it "dismisses when report_main_concern was filed this iteration and base_retry confirms the same grader also fails on base" do
    run = repair_run_for_grader_step
    MainConcernReport.create!(repository: job.repository, job: job, workflow: workflow, run: run, reason: "flaky simulator, reproduces on base too")
    allow(BaseRevisionRetry).to receive(:call).and_return(
      BaseRevisionRetry::Result.new(
        ran: true, inherited: true, reason: "base_retry_full_command_failed_different_output",
        command: "bin/simulator", base_failed_identities: [], introduced_failed_identities: [], output: "boom"
      )
    )

    verdict = adjudicate

    expect(verdict).to be_dismiss
    expect(verdict.reason).to eq("main_concern_verified_by_base_retry")
    expect(verdict.evidence).to include(base_sha: "base123", grader_names: [ "work-engine-simulations" ])
  end

  it "declines without a base_sha even when report_main_concern was filed" do
    run = repair_run_for_grader_step
    MainConcernReport.create!(repository: job.repository, job: job, workflow: workflow, run: run, reason: "looks pre-existing")

    verdict = adjudicate(base_sha: nil)

    expect(verdict).to be_inconclusive
    expect(verdict.reason).to eq("no_base_sha")
  end
end
