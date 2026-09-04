require "rails_helper"

RSpec.describe Decisions::Opener do
  let(:job) { Factories.job }
  let(:repo) { job.repository }
  let(:problem) { Problem[:grader_failure, evidence: { grader_name: "rspec" }] }

  def open(**overrides)
    described_class.call(**{ problem: problem, title: "rspec failed", job: job }.merge(overrides))
  end

  it "opens a decision for a problem nobody has seen" do
    result = open

    expect(result).to be_created
    expect(result.decision.problem_code).to eq("grader_failure")
    expect(result.decision.repository).to eq(repo)
  end

  # The tenth occurrence of one problem is one row, not ten.
  it "reuses the open decision for the same signature" do
    first = open.decision
    result = open

    expect(result).not_to be_created
    expect(result.decision).to eq(first)
    expect(Decision.count).to eq(1)
  end

  # This is what makes attention compound rather than merely reformat.
  it "does not ask again once the same problem has been decided" do
    open.decision.decide!(resolution: "dismissed", user: repo.user, reason: "known upstream issue")

    result = open

    expect(result).not_to be_created
    expect(result.decision).to be_nil
    expect(result).to be_answered_by_prior
    expect(result.prior.reason).to eq("known upstream issue")
  end

  # A dismissal that made sense against one base revision should not silently
  # outlive it.
  it "asks again once a prior decision has expired" do
    prior = open.decision
    prior.decide!(resolution: "dismissed", user: repo.user)
    prior.update!(expires_at: 1.hour.ago)

    expect(open).to be_created
  end

  # A dismissal that was right for one project is not evidence about another.
  it "does not apply another repository's decision" do
    open.decision.decide!(resolution: "dismissed", user: repo.user)
    other_job = Factories.job

    result = described_class.call(problem: problem, title: "rspec failed", job: other_job)

    expect(result).to be_created
  end

  it "records the adjudicator's verdict alongside the problem" do
    verdict = Adjudication.dismiss(reason: "inherited", adjudicator: "inherited_grader_failure")

    decision = open(adjudication: verdict).decision

    expect(decision.adjudication).to include("verdict" => "dismiss", "reason" => "inherited")
  end
end
