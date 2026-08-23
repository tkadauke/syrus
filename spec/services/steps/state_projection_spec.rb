require "rails_helper"

RSpec.describe Steps::StateProjection do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository) }
  let(:workflow) { Workflow.create!(job: job, trigger_kind: "initial", state: "running") }

  it "uses the active run as the visible state when the persisted step state is stale" do
    step = Step.create!(workflow: workflow, kind: "implement", position: 0, state: "queued")
    run = Run.create!(job: job, step: step, trigger_kind: "initial", state: "running")

    projection = described_class.for(step, runs: [ run ])

    expect(projection.visible_state).to eq("running")
    expect(projection).to be_active
    expect(projection).to be_drifted
  end

  it "uses the latest terminal run when no active run remains" do
    step = Step.create!(workflow: workflow, kind: "grader", position: 0, state: "running")
    older = Run.create!(job: job, step: step, trigger_kind: "initial", state: "failed", created_at: 2.minutes.ago)
    latest = Run.create!(job: job, step: step, trigger_kind: "initial", state: "succeeded", created_at: 1.minute.ago)

    projection = described_class.for(step, runs: [ latest, older ])

    expect(projection.visible_state).to eq("succeeded")
    expect(projection).to be_terminal
    expect(projection.latest_terminal_run).to eq(latest)
  end

  it "falls back to the persisted step state when there are no runs" do
    step = Step.create!(workflow: workflow, kind: "prepare", position: 0, state: "queued")

    projection = described_class.for(step, runs: [])

    expect(projection.visible_state).to eq("queued")
    expect(projection).not_to be_drifted
  end
end
