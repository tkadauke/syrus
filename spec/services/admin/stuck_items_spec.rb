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

  it "preloads affected Workflows without sorting wide Step rows across an id list" do
    user = Factories.user
    repository = Factories.repository(user: user)
    # Several Workflows, so the Step preload batches their ids into an IN list.
    # With one id Rails emits `workflow_id = ?`, which the (workflow_id,
    # position) index serves and which would hide the regression entirely.
    issues = [ 100, 101, 102 ].map do |issue_number|
      job = Factories.job(user: user, repository: repository, issue_number: issue_number)
      workflow = Workflow.create!(job: job, user: user, trigger_kind: "initial", state: "running")
      Step.create!(workflow: workflow, kind: "grader", position: 1, state: "running",
        details: { "output" => "x" * 2_048 })
      WorkEngine::Reconciler::Issue.new(
        kind: :stale_run,
        severity: :warning,
        evidence: {},
        affected_ids: { workflow_ids: [ workflow.id ], job_ids: [ job.id ] },
        safe_to_auto_repair: false,
        recommended_repair_action: :wait_for_worker,
        explanation: "Synthetic issue."
      )
    end
    result = WorkEngine::Reconciler::Result.new("spec", Time.current, nil, issues, [ nil ] * issues.size, [])
    stuck_items = described_class.new(result: result)

    offenders = wide_row_sort_statements { stuck_items.all }

    expect(offenders).to be_empty
  end

  it "still attaches each affected Workflow's Steps in position order" do
    user = Factories.user
    repository = Factories.repository(user: user)
    job = Factories.job(user: user, repository: repository)
    workflow = Workflow.create!(job: job, user: user, trigger_kind: "initial", state: "running")
    third = Step.create!(workflow: workflow, kind: "grader", position: 3, state: "queued")
    first = Step.create!(workflow: workflow, kind: "implement", position: 1, state: "succeeded")
    second = Step.create!(workflow: workflow, kind: "summarize", position: 2, state: "running")
    issue = WorkEngine::Reconciler::Issue.new(
      kind: :stale_run,
      severity: :warning,
      evidence: {},
      affected_ids: { workflow_ids: [ workflow.id ], job_ids: [ job.id ] },
      safe_to_auto_repair: false,
      recommended_repair_action: :wait_for_worker,
      explanation: "Synthetic issue."
    )
    stuck_items = described_class.new(result: result_for(issue))
    stuck_items.send(:preload_records, [ issue ])

    preloaded = stuck_items.send(:record_maps).fetch(Workflow).fetch(workflow.id)

    expect(preloaded.steps.map(&:id)).to eq([ first.id, second.id, third.id ])
    # The inverse a real preload would set: without it `step.workflow`
    # re-queries and hands back a second instance.
    expect(preloaded.steps.first.workflow).to equal(preloaded)
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
