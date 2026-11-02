require "rails_helper"

RSpec.describe WorkspaceReuseOutcomes::Summary do
  it "groups outcomes by repository, fingerprint, backend, kind, and outcome" do
    job = Factories.job
    workflow = job.workflows.last
    step = workflow.steps.first
    run = step.runs.first || step.runs.create!(job: job, trigger_kind: workflow.trigger_kind)
    2.times do
      WorkspaceReuseOutcome.create!(
        repository: job.repository,
        workflow: workflow,
        step: step,
        run: run,
        kind: "prepare",
        outcome: "reused_from_archive",
        prepare_fingerprint: "fingerprint",
        backend: "local",
        occurred_at: 1.hour.ago
      )
    end

    expect(described_class.call(since: 1.day.ago, repository: job.repository)).to contain_exactly(
      include(
        repository_id: job.repository_id,
        prepare_fingerprint: "fingerprint",
        backend: "local",
        outcomes: { "reused_from_archive" => 2 },
        total_count: 2,
        reuse_rate: 1.0
      )
    )
  end

  it "excludes skipped prepares and rows after the requested window from reuse rate" do
    job = Factories.job
    workflow = job.workflows.last
    step = workflow.steps.first
    run = step.runs.first || step.runs.create!(job: job, trigger_kind: workflow.trigger_kind)
    attributes = {
      repository: job.repository, workflow: workflow, step: step, run: run,
      kind: "prepare", prepare_fingerprint: "fingerprint", backend: "local"
    }
    WorkspaceReuseOutcome.create!(**attributes, outcome: "reused_from_archive", occurred_at: 2.hours.ago)
    WorkspaceReuseOutcome.create!(**attributes, outcome: "rebuilt", occurred_at: 90.minutes.ago)
    WorkspaceReuseOutcome.create!(**attributes, outcome: "skipped", occurred_at: 1.hour.ago)
    WorkspaceReuseOutcome.create!(**attributes, outcome: "rebuilt", occurred_at: 5.minutes.ago)

    result = described_class.call(
      since: 3.hours.ago,
      until_time: 30.minutes.ago,
      repository: job.repository
    ).sole

    expect(result).to include(total_count: 3, reuse_rate: 0.5)
    expect(result[:outcomes]).to eq("reused_from_archive" => 1, "rebuilt" => 1, "skipped" => 1)
  end
end
