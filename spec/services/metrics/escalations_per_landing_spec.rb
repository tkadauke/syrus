require "rails_helper"

RSpec.describe Metrics::EscalationsPerLanding do
  let(:job) { Factories.job }
  let(:repo) { job.repository }

  def landing!(finished_at: 1.hour.ago, state: "succeeded")
    job.workflows.create!(
      trigger_kind: "auto_merge", state: state, user: job.user, finished_at: finished_at
    )
  end

  def escalation!(created_at: 1.hour.ago, problem_code: "grader_failure")
    Decision.create!(
      problem_code: problem_code, signature: "#{problem_code}:#{SecureRandom.hex(4)}",
      title: "t", repository: repo, created_at: created_at
    )
  end

  it "is zero when work landed without costing anyone attention" do
    landing!
    landing!

    result = described_class.call

    expect(result.landings).to eq(2)
    expect(result.escalations).to eq(0)
    expect(result.ratio).to eq(0.0)
  end

  it "divides escalations by landings" do
    2.times { landing! }
    3.times { escalation! }

    expect(described_class.call.ratio).to be_within(0.001).of(1.5)
  end

  # An infinity would read as a number; "no landings" is the honest answer.
  it "has no ratio when nothing landed" do
    escalation!

    result = described_class.call

    expect(result.ratio).to be_nil
    expect(result.to_s).to eq("no landings in window")
  end

  it "ignores work outside the window" do
    landing!(finished_at: 30.days.ago)
    escalation!(created_at: 30.days.ago)

    result = described_class.call(from: 7.days.ago)

    expect(result.landings).to eq(0)
    expect(result.escalations).to eq(0)
  end

  it "does not count a landing attempt that failed" do
    landing!(state: "failed")

    expect(described_class.call.landings).to eq(0)
  end

  it "breaks escalations down by problem so a trend can be read" do
    escalation!(problem_code: "grader_failure")
    escalation!(problem_code: "grader_failure")
    escalation!(problem_code: "timeout")

    expect(described_class.call.by_problem_code).to eq("grader_failure" => 2, "timeout" => 1)
  end

  it "scopes to one repository when asked" do
    escalation!
    other_repo = Factories.repository

    expect(described_class.call(repository: other_repo).escalations).to eq(0)
    expect(described_class.call(repository: repo).escalations).to eq(1)
  end
end
