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
end
