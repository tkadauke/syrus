require "rails_helper"

RSpec.describe Admin::StuckItems do
  def result_for(issue)
    WorkEngine::Reconciler::Result.new(
      "spec",
      Time.current,
      nil,
      [ issue ],
      [ nil ],
      []
    )
  end

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
    result = result_for(issue)

    stuck_items = described_class.new(result: result)
    stuck_items.send(:preload_records, [ issue ])

    expect(stuck_items.send(:record_maps).fetch(Run).keys).to eq([ primary_run.id ])
    expect(stuck_items.all.first.run).to eq(primary_run)
    expect(stuck_items.all.first.run).not_to eq(extra_run)
  end

  it "renders dependency detail for Jobs blocked by unreleased Epics" do
    user = Factories.user
    repository = Factories.repository(user: user)
    epic = Factories.epic(user: user, repository: repository, state: "ready")
    job = Factories.job_record(user: user, repository: repository, epic: epic, state: "queued")
    issue = WorkEngine::Reconciler::Issue.new(
      kind: :dependency_stack_start_block,
      severity: :warning,
      evidence: {},
      affected_ids: { job_ids: [ job.id ] },
      safe_to_auto_repair: false,
      recommended_repair_action: :wait_for_dependency_or_stack_readiness,
      explanation: "Job dependencies are not ready."
    )

    item = described_class.new(result: result_for(issue)).all.sole

    expect(item.detail).to eq("Dependency blocked: Job dependencies are not ready.")
  end
end
