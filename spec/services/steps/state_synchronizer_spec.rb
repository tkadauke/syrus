require "rails_helper"

RSpec.describe Steps::StateSynchronizer do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository) }
  let(:workflow) { Workflow.create!(job: job, trigger_kind: "initial", state: "running") }

  it "moves an active step to the latest terminal run state" do
    step = Step.create!(workflow: workflow, kind: "grader", position: 0, state: "running")
    older = Run.create!(job: job, step: step, trigger_kind: "initial", state: "failed", created_at: 3.minutes.ago)
    latest = Run.create!(job: job, step: step, trigger_kind: "initial", state: "succeeded", created_at: 2.minutes.ago)

    result = described_class.from_latest_terminal_run!(step, runs: [ latest, older ])

    expect(result).to be_synchronized
    expect(result.run).to eq(latest)
    expect(step.reload).to be_succeeded
  end

  it "does not move a step while an active run still exists" do
    step = Step.create!(workflow: workflow, kind: "grader", position: 0, state: "running")
    failed = Run.create!(job: job, step: step, trigger_kind: "initial", state: "failed", created_at: 3.minutes.ago)
    running = Run.create!(job: job, step: step, trigger_kind: "initial", state: "running", created_at: 2.minutes.ago)

    result = described_class.from_latest_terminal_run!(step, runs: [ failed, running ])

    expect(result).not_to be_synchronized
    expect(result.reason).to eq("Step still has active Runs")
    expect(step.reload).to be_running
  end

  it "supports skipped runs as benign terminal attempts" do
    step = Step.create!(workflow: workflow, kind: "grader", position: 0, state: "queued")
    skipped = Run.create!(job: job, step: step, trigger_kind: "initial", state: "skipped")

    result = described_class.from_latest_terminal_run!(step, runs: [ skipped ])

    expect(result).to be_synchronized
    expect(step.reload).to be_skipped
  end
end
