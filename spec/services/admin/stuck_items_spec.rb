require "rails_helper"

RSpec.describe Admin::StuckItems do
  it "preloads only primary affected ids used by item serialization" do
    user = Factories.user
    repository = Factories.repository(user: user)
    job = Factories.job(user: user, repository: repository)
    workflow = Workflow.create!(job: job, user: user, trigger_kind: "initial", state: "running")
    step = Step.create!(workflow: workflow, kind: "implement", position: 1, state: "running")
    primary_run = Run.create!(job: job, user: user, step: step, trigger_kind: "initial", state: "running")
    extra_run = Run.create!(job: job, user: user, step: step, trigger_kind: "initial", state: "failed")
    issue = WorkEngine::Reconciler::Issue.new(
      kind: :stale_run,
      severity: :warning,
      evidence: { "started_at" => primary_run.created_at.iso8601 },
      affected_ids: {
        run_ids: [ primary_run.id, extra_run.id ],
        workflow_ids: [ workflow.id ],
        job_ids: [ job.id ]
      },
      safe_to_auto_repair: false,
      recommended_repair_action: :wait_for_worker,
      explanation: "Synthetic issue."
    )
    result = WorkEngine::Reconciler::Result.new(
      "spec",
      Time.current,
      nil,
      [ issue ],
      [ nil ],
      []
    )

    stuck_items = described_class.new(result: result)
    stuck_items.send(:preload_records, [ issue ])

    expect(stuck_items.send(:record_maps).fetch(Run).keys).to eq([ primary_run.id ])
    expect(stuck_items.all.first.run).to eq(primary_run)
    expect(stuck_items.all.first.run).not_to eq(extra_run)
  end
end
