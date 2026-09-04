require "rails_helper"

RSpec.describe Decisions::Escalator do
  let(:job) { Factories.job }
  let(:workflow) { job.workflows.first }
  let(:step) { workflow.steps.first }

  def fail_workflow!(problem_code: nil)
    step.update!(state: "failed", details: step.details.to_h.merge({ "problem_code" => problem_code }.compact))
    workflow.update!(state: "failed", failure_reason: "required graders failed: rspec")
  end

  it "opens no decision for a workflow that has not failed" do
    expect(described_class.call(workflow: workflow)).to be_nil
  end

  it "opens no decision when the failure cannot be named in the shared vocabulary" do
    fail_workflow!

    expect(described_class.call(workflow: workflow)).to be_nil
  end

  it "opens a decision for a classified failure" do
    fail_workflow!(problem_code: "grader_failure")

    result = described_class.call(workflow: workflow)

    expect(result).to be_created
    expect(result.decision.problem_code).to eq("grader_failure")
    expect(result.decision.workflow).to eq(workflow)
    expect(result.decision.summary).to eq("required graders failed: rspec")
  end

  it "offers the retry action an operator already has" do
    fail_workflow!(problem_code: "grader_failure")

    expect(described_class.call(workflow: workflow).decision.action_keys).to eq([ "retry_job" ])
  end

  # A stalled landing is the expensive failure; a failed initial attempt is
  # normal and cheap.
  it "ranks a stalled landing above a failed initial attempt" do
    fail_workflow!(problem_code: "grader_failure")
    expect(described_class.call(workflow: workflow).decision.urgency).to eq("low")

    workflow.update!(trigger_kind: "auto_merge")
    Decision.delete_all
    expect(described_class.call(workflow: workflow).decision.urgency).to eq("urgent")
  end

  it "carries the rung-0 verdict onto the decision" do
    workflow.set_artifact!("rung_zero_adjudication", { "verdict" => "inconclusive", "reason" => "no_adjudicator_decided" })
    fail_workflow!(problem_code: "grader_failure")

    expect(described_class.call(workflow: workflow).decision.adjudication)
      .to include("verdict" => "inconclusive")
  end

  # One decision per distinct problem, not per occurrence -- which is what
  # makes the escalations-per-landing metric mean anything.
  it "does not file a second decision for a problem already open" do
    fail_workflow!(problem_code: "grader_failure")
    described_class.call(workflow: workflow)

    expect(described_class.call(workflow: workflow)).not_to be_created
    expect(Decision.count).to eq(1)
  end
end
