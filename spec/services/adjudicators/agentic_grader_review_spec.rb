require "rails_helper"

RSpec.describe Adjudicators::AgenticGraderReview do
  let(:job) { Factories.job }
  let(:workflow) { job.workflows.first }
  let(:grader_step) do
    workflow.steps.first.tap { |step| step.update!(details: { "name" => "rspec", "output" => "3 failures" }) }
  end

  def stub_judgment(value, failed: false, error: nil)
    result = if failed
      Judgment::Result.new(value: nil, raw_text: nil, problem: Problem[:timeout, evidence: { reason: error }], cost_usd: nil)
    else
      Judgment::Result.new(value: value, raw_text: nil, problem: nil, cost_usd: 0.02)
    end
    allow(Judgment).to receive(:call).and_return(result)
  end

  def adjudicate(trigger_kind: "auto_merge")
    workflow.update!(trigger_kind: trigger_kind)
    described_class.adjudicate(problem: Problem[:grader_failure], workflow: workflow, step: [ grader_step ])
  end

  # It costs a turn every time it runs.
  it "declines outright when the ladder does not include rung 3" do
    expect(Judgment).not_to receive(:call)

    verdict = adjudicate(trigger_kind: "initial")

    expect(verdict).to be_inconclusive
    expect(verdict.reason).to eq("ladder_excludes_rung_3")
  end

  it "declines for a problem that is not a grader failure" do
    expect(described_class.adjudicate(problem: Problem[:timeout], workflow: workflow)).to be_inconclusive
  end

  it "dismisses a failure the adjudicator is confident predates the branch" do
    stub_judgment({ "verdict" => "dismiss", "confidence" => 0.9, "reason" => "same 3 examples fail on base",
                    "evidence" => [ "base_sha:a1b2c3" ] })

    verdict = adjudicate

    expect(verdict).to be_dismiss
    expect(verdict.confidence).to eq(0.9)
    expect(verdict.reason).to eq("same 3 examples fail on base")
    expect(verdict.evidence[:cited]).to eq([ "base_sha:a1b2c3" ])
  end

  it "upholds a failure the adjudicator attributes to the branch" do
    stub_judgment({ "verdict" => "uphold", "confidence" => 0.95, "reason" => "new spec added by this branch" })

    expect(adjudicate).to be_uphold
  end

  # A low-confidence verdict is the model telling us it could not tell.
  it "treats a low-confidence verdict as inconclusive" do
    stub_judgment({ "verdict" => "dismiss", "confidence" => 0.3, "reason" => "maybe" })

    verdict = adjudicate

    expect(verdict).to be_inconclusive
    expect(verdict.reason).to match(/low_confidence/)
  end

  it "does not require confidence to say it cannot tell" do
    stub_judgment({ "verdict" => "inconclusive", "confidence" => 0.1, "reason" => "cannot see the base" })

    expect(adjudicate).to be_inconclusive
  end

  it "treats an unrecognized verdict as inconclusive rather than guessing" do
    stub_judgment({ "verdict" => "probably_fine", "confidence" => 0.99, "reason" => "eh" })

    expect(adjudicate.reason).to match(/unknown_verdict/)
  end

  it "declines when the judgment itself failed" do
    stub_judgment(nil, failed: true, error: "timed out after 60s")

    expect(adjudicate.reason).to match(/judgment_failed/)
  end

  # The adjudicator must never be the agent that produced the diff; Judgment
  # runs a fresh session with no workspace.
  it "asks through the Judgment primitive rather than resuming a session" do
    expect(Judgment).to receive(:call).with(hash_including(scope: "grader-adjudication")).and_return(
      Judgment::Result.new(value: { "verdict" => "inconclusive", "reason" => "x" }, raw_text: nil, problem: nil, cost_usd: nil)
    )

    adjudicate
  end
end
